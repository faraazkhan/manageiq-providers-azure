class ManageIQ::Providers::Azure::Inventory::Collector < ManagerRefresh::Inventory::Collector
  require_nested :CloudManager
  require_nested :NetworkManager
  require_nested :TargetCollection

  # TODO: cleanup later when old refresh is deleted
  include ManageIQ::Providers::Azure::RefreshHelperMethods
  include Vmdb::Logging

  attr_reader :subscription_id, :stacks_resources_cache

  def initialize(manager, _target)
    super

    @ems = manager # used in helper methods

    # TODO(lsmola) this takes about 4s, see if we can optimize it
    @config          = manager.connect

    @subscription_id = @config.subscription_id
    @thread_limit    = (options.parallel_thread_limit || 0)
    @record_limit    = (options.targeted_api_collection_threshold || 500).to_i

    @enabled_deployments_caching = options.enabled_deployments_caching.nil? ? true : options.enabled_deployments_caching

    # Caches for optimizing fetching resources and templates of stacks
    @stacks_not_changed_cache = {}
    @stacks_resources_cache = {}
    @stacks_resources_api_cache = {}
    @instances_power_state_cache = {}
    @indexed_instance_account_keys_cache = {}

    @resource_to_stack = {}
    @template_uris     = {} # templates need to be download
    @template_refs     = {} # templates need to be retrieved from VMDB
    @template_directs  = {} # templates contents already got by API

    @nis  = network_interface_service(@config)
    @ips  = ip_address_service(@config)
    @vmm  = virtual_machine_service(@config)
    @asm  = availability_set_service(@config)
    @tds  = template_deployment_service(@config)
    @rgs  = resource_group_service(@config)
    @sas  = storage_account_service(@config)
    @sds  = storage_disk_service(@config)
    @mis  = managed_image_service(@config)
    @vmis = virtual_machine_image_service(@config, :location => @ems.provider_region)

    @vns = virtual_network_service(@config)
    @nsg = network_security_group_service(@config)
    @lbs = load_balancer_service(@config)
    @rts = route_table_service(@config)
  end

  ##############################################################
  # Shared helpers for full and targeted CloudManager collectors
  ##############################################################
  def managed_disks
    @managed_disks ||= collect_inventory(:managed_disks) { @sds.list_all }
  end

  def storage_accounts
    # We want to always limit storage accounts, to avoid loading all account keys in full refresh. Right now we want to
    # load just used storage accounts.
    return if instances.blank?

    used_storage_accounts = instances.map do |instance|
      disks = instance.properties.storage_profile.data_disks + [instance.properties.storage_profile.os_disk]
      disks.map do |disk|
        next if instance.managed_disk?
        disk_location = disk.try(:vhd).try(:uri)
        if disk_location
          uri = Addressable::URI.parse(disk_location)
          uri.host.split('.').first
        end
      end
    end.flatten.compact.to_set

    @storage_accounts ||= collect_inventory(:storage_accounts) { @sas.list_all }.select do |x|
      used_storage_accounts.include?(x.name)
    end
  end

  def stack_resources(deployment)
    cached_stack_resources = stacks_resources_api_cache[deployment.id]
    return cached_stack_resources if cached_stack_resources

    raw_stack_resources(deployment)
  end

  def power_status(instance)
    cached_power_state = instances_power_state_cache[instance.id]
    return cached_power_state if cached_power_state

    raw_power_status(instance)
  end

  def network_ports
    @network_interfaces ||= collect_inventory(:network_ports) { gather_data_for_this_region(@nis) }
  end

  def network_routers
    @network_routers ||= collect_inventory(:network_routers) { gather_data_for_this_region(@rts) }
  end

  def floating_ips
    @floating_ips ||= collect_inventory(:floating_ips) { gather_data_for_this_region(@ips) }
  end

  def instance_network_ports(instance)
    @indexed_network_ports ||= network_ports.index_by(&:id)

    instance.properties.network_profile.network_interfaces.map { |x| @indexed_network_ports[x.id] }.compact
  end

  def instance_floating_ip(public_ip_obj)
    @indexed_floating_ips ||= floating_ips.index_by(&:id)

    @indexed_floating_ips[public_ip_obj.id]
  end

  def instance_managed_disk(disk_location)
    @indexed_managed_disks ||= managed_disks.index_by { |x| x.id.downcase }

    @indexed_managed_disks[disk_location.downcase]
  end

  def instance_account_keys(storage_acct)
    instance_account_keys_advanced_caching unless @instance_account_keys_advanced_caching_done
    @instance_account_keys_advanced_caching_done = true

    indexed_instance_account_keys_cache[[storage_acct.name, storage_acct.resource_group]]
  end

  def instance_storage_accounts(storage_name)
    @indexes_instance_storage_accounts ||= storage_accounts.index_by { |x| x.name.downcase }

    @indexes_instance_storage_accounts[storage_name.downcase]
  end

  def stacks
    @stacks_cache ||= collect_inventory(:deployments) { stacks_in_parallel(@tds, 'list') }

    stacks_advanced_caching(@stacks_cache) unless @stacks_advanced_caching_done
    @stacks_advanced_caching_done = true

    @stacks_cache
  end

  def stack_templates
    stacks.each do |deployment|
      # Do not fetch templates for stacks we already have in DB and that haven't changed
      next if stacks_not_changed_cache[deployment.id]

      stack_template_hash(deployment)
    end

    # download all template uris
    _log.info("Retrieving templates...")
    @template_uris.each { |uri, template| template[:content] = download_template(uri) }
    _log.info("Retrieving templates...Complete - Count [#{@template_uris.count}]")
    _log.debug("Memory usage: #{'%.02f' % collector_memory_usage} MiB")

    (@template_uris.values + @template_directs.values).select do |raw|
      raw[:content]
    end
  end

  def stack_template_hash(deployment)
    direct_stack_template(deployment) || uri_stack_template(deployment)
  end

  def direct_stack_template(deployment)
    content = @tds.get_template(deployment.name, deployment.resource_group)
    init_template_hash(deployment, content.to_s).tap do |template_hash|
      @template_directs[deployment.id] = template_hash
    end
  rescue ::Azure::Armrest::ConflictException
    # Templates were not saved for deployments created before 03/20/2016
    nil
  end

  def uri_stack_template(deployment)
    uri = deployment.properties.try(:template_link).try(:uri)
    return unless uri
    @template_uris[uri] ||
      init_template_hash(deployment).tap do |template_hash|
        @template_uris[uri] = template_hash
      end
  end

  def init_template_hash(deployment, content = nil)
    # If content is nil it is to be fetched
    ver = deployment.properties.try(:template_link).try(:content_version)
    {
      :description => "contentVersion: #{ver}",
      :name        => deployment.name,
      :uid         => deployment.id,
      :content     => content
    }
  end

  def download_template(uri)
    options = {
      :method      => 'get',
      :url         => uri,
      :proxy       => @config.proxy,
      :ssl_version => @config.ssl_version,
      :ssl_verify  => @config.ssl_verify
    }

    body = RestClient::Request.execute(options).body
    JSON.parse(body).to_s # normalize to remove white spaces
  rescue StandardError => e
    _log.error("Failed to download Azure template #{uri}. Reason: #{e.inspect}")
    nil
  end

  protected

  attr_reader :record_limit, :enabled_deployments_caching
  attr_writer :stacks_resources_cache
  attr_accessor :stacks_not_changed_cache, :stacks_resources_api_cache, :instances_power_state_cache,
                :indexed_instance_account_keys_cache

  # Do not use threads in test environment in order to avoid breaking specs.
  #
  # @return [Integer] Number of threads we will use for API collections
  def thread_limit
    Rails.env.test? ? 0 : @thread_limit
  end

  def stacks_resources_advanced_caching(stacks)
    return if stacks.blank?

    # Fetch resources for stack, but only the stacks that changed
    results = collect_inventory_targeted("stacks_resources") do
      Parallel.map(stacks, :in_threads => thread_limit) do |stack|
        [stack.id, raw_stack_resources(stack)]
      end
    end

    stacks_resources_api_cache.merge!(results.to_h)
  end

  def instances_power_state_advanced_caching(instances)
    return if instances.blank?

    if instances_power_state_cache.blank?
      results = collect_inventory_targeted("instance_power_states") do
        Parallel.map(instances, :in_threads => thread_limit) do |instance|
          [instance.id, raw_power_status(instance)]
        end
      end

      self.instances_power_state_cache = results.to_h
    end
  end

  def stacks_advanced_caching(stacks, refs = nil)
    if enabled_deployments_caching
      db_stacks_timestamps              = {}
      db_stacks_primary_keys            = {}
      db_stacks_primary_keys_to_ems_ref = {}

      query = manager.orchestration_stacks
      query = query.where(:ems_ref => refs) if refs

      query.find_each do |stack|
        db_stacks_timestamps[stack.ems_ref]         = stack.finish_time
        db_stacks_primary_keys[stack.ems_ref]       = stack.id
        db_stacks_primary_keys_to_ems_ref[stack.id] = stack.ems_ref
      end

      stacks.each do |deployment|
        next if (api_timestamp = deployment.properties.timestamp).blank?
        next if (db_timestamp = db_stacks_timestamps[deployment.id]).nil?

        api_timestamp = Time.parse(api_timestamp).utc
        db_timestamp = db_timestamp.utc
        # If there isn't a new version of stack, we take times are equal if the difference is below 1s
        next if (db_timestamp < api_timestamp) && ((db_timestamp - api_timestamp).abs > 1.0)

        stacks_not_changed_cache[deployment.id] = db_stacks_primary_keys[deployment.id]
      end

      # Cache resources from the DB
      not_changed_stacks_ids = db_stacks_primary_keys.values
      not_changed_stacks_ids.each_slice(1000) do |batch|
        manager.orchestration_stacks_resources.where(:stack_id => batch).each do |resource|
          ems_ref = db_stacks_primary_keys_to_ems_ref[resource.stack_id]
          next unless ems_ref

          (stacks_resources_cache[ems_ref] ||= []) << parse_db_resource(resource)
        end
      end

      # Cache resources from the API
      stacks_resources_advanced_caching(stacks.reject { |x| stacks_not_changed_cache[x.id] })
    end
  end

  def instance_account_keys_advanced_caching
    return if storage_accounts.blank?

    acc_keys = Parallel.map(storage_accounts, :in_threads => thread_limit) do |storage_acct|
      [
        [storage_acct.name, storage_acct.resource_group],
        collect_inventory(:account_keys) { @sas.list_account_keys(storage_acct.name, storage_acct.resource_group) }
      ]
    end

    indexed_instance_account_keys_cache.merge!(acc_keys.to_h)
  end

  def safe_targeted_request
    yield
  rescue ::Azure::Armrest::Exception => err
    _log.debug("Record not found Error Class=#{err.class.name}, Message=#{err.message}")
    nil
  end

  private

  def raw_stack_resources(deployment)
    group = deployment.resource_group
    name  = deployment.name

    resources = collect_inventory(:stack_resources) { @tds.list_deployment_operations(name, group) }
    # resources with provsioning_operation 'Create' are the ones created by this stack
    resources.select! do |resource|
      resource.properties.provisioning_operation =~ /^create$/i
    end

    resources
  rescue ::Azure::Armrest::Exception => err
    _log.debug("Records not found Error Class=#{err.class.name}, Message=#{err.message}")
    []
  end

  def raw_power_status(instance)
    view   = @vmm.get_instance_view(instance.name, instance.resource_group)
    status = view.statuses.find { |s| s.code =~ %r{^PowerState/} }
    status&.display_status
  rescue ::Azure::Armrest::NotFoundException
    'off' # Possible race condition caused by retirement deletion.
  end

  def parse_db_resource(resource)
    {
      :ems_ref                => resource.ems_ref,
      :name                   => resource.name,
      :logical_resource       => resource.logical_resource,
      :physical_resource      => resource.physical_resource,
      :resource_category      => resource.resource_category,
      :resource_status        => resource.resource_status,
      :resource_status_reason => resource.resource_status_reason,
      :last_updated           => resource.last_updated
    }
  end

  def stacks_in_parallel(arm_service, method_name)
    region = @ems.provider_region

    Parallel.map(resource_groups, :in_threads => thread_limit) do |resource_group|
      arm_service.send(method_name, resource_group.name).select do |resource|
        location = resource.respond_to?(:location) ? resource.location : resource_group.location
        location.casecmp(region).zero?
      end
    end.flatten
  end
end
