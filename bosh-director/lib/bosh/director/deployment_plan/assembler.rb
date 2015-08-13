module Bosh::Director
  # DeploymentPlan::Assembler is used to populate deployment plan with information
  # about existing deployment and information from director DB
  class DeploymentPlan::Assembler
    include LockHelper
    include IpUtil

    def initialize(deployment_plan, stemcell_manager, cloud, blobstore, logger, event_log)
      @deployment_plan = deployment_plan
      @cloud = cloud
      @logger = logger
      @event_log = event_log
      @stemcell_manager = stemcell_manager
      @blobstore = blobstore
    end

    # Binds release DB record(s) to a plan
    # @return [void]
    def bind_releases
      releases = @deployment_plan.releases
      with_release_locks(releases.map(&:name)) do
        releases.each do |release|
          release.bind_model
        end
      end
    end

    def current_states_by_instance(existing_instances)
      lock = Mutex.new
      current_states_by_existing_instance = {}
      ThreadPool.new(:max_threads => Config.max_threads).wrap do |pool|
        existing_instances.each do |existing_instance|
          if existing_instance.vm
            pool.process do
              with_thread_name("binding agent state for (#{existing_instance.job}/#{existing_instance.index})") do
                # getting current state to obtain IP of dynamic networks
                state = get_state(existing_instance.vm)
                lock.synchronize do
                  current_states_by_existing_instance.merge!(existing_instance => state)
                end
              end
            end
          end
        end
      end
      current_states_by_existing_instance
    end

    def mark_unknown_vms_for_deletion
      @deployment_plan.vm_models.select { |vm| vm.instance.nil? }.each do |vm_model|
        # VM without an instance should not exist any more. But we still
        # delete those VMs for backwards compatibility in case if it was ever
        # created incorrectly.
        # It also means that it was created before global networking
        # and should not have any network reservations in DB,
        # so we don't worry about releasing its IPs.
        @logger.debug('Marking VM for deletion')
        @deployment_plan.mark_vm_for_deletion(vm_model)
      end
    end

    def get_state(vm_model)
      @logger.debug("Requesting current VM state for: #{vm_model.agent_id}")
      agent = AgentClient.with_vm(vm_model)
      state = agent.get_state

      @logger.debug("Received VM state: #{state.pretty_inspect}")
      verify_state(vm_model, state)
      @logger.debug('Verified VM state')

      migrate_legacy_state(vm_model, state)
      state.delete('release')
      if state.include?('job')
        state['job'].delete('release')
      end
      state
    end

    def verify_state(vm_model, state)
      instance = vm_model.instance

      if instance && instance.deployment_id != vm_model.deployment_id
        # Both VM and instance should reference same deployment
        raise VmInstanceOutOfSync,
              "VM `#{vm_model.cid}' and instance " +
              "`#{instance.job}/#{instance.index}' " +
              "don't belong to the same deployment"
      end

      unless state.kind_of?(Hash)
        @logger.error("Invalid state for `#{vm_model.cid}': #{state.pretty_inspect}")
        raise AgentInvalidStateFormat,
              "VM `#{vm_model.cid}' returns invalid state: " +
              "expected Hash, got #{state.class}"
      end

      actual_deployment_name = state['deployment']
      expected_deployment_name = @deployment_plan.name

      if actual_deployment_name != expected_deployment_name
        raise AgentWrongDeployment,
              "VM `#{vm_model.cid}' is out of sync: " +
                'expected to be a part of deployment ' +
              "`#{expected_deployment_name}' " +
                'but is actually a part of deployment ' +
              "`#{actual_deployment_name}'"
      end

      actual_job = state['job'].is_a?(Hash) ? state['job']['name'] : nil
      actual_index = state['index']

      if instance.nil? && !actual_job.nil?
        raise AgentUnexpectedJob,
              "VM `#{vm_model.cid}' is out of sync: " +
              "it reports itself as `#{actual_job}/#{actual_index}' but " +
                'there is no instance reference in DB'
      end

      if instance &&
        (instance.job != actual_job || instance.index != actual_index)
        # Check if we are resuming a previously unfinished rename
        if actual_job == @deployment_plan.job_rename['old_name'] &&
           instance.job == @deployment_plan.job_rename['new_name'] &&
           instance.index == actual_index

          # Rename already happened in the DB but then something happened
          # and agent has never been updated.
          unless @deployment_plan.job_rename['force']
            raise AgentRenameInProgress,
                  "Found a job `#{actual_job}' that seems to be " +
                  "in the middle of a rename to `#{instance.job}'. " +
                  "Run 'rename' again with '--force' to proceed."
          end
        else
          raise AgentJobMismatch,
                "VM `#{vm_model.cid}' is out of sync: " +
                "it reports itself as `#{actual_job}/#{actual_index}' but " +
                "according to DB it is `#{instance.job}/#{instance.index}'"
        end
      end
    end

    def migrate_legacy_state(vm_model, state)
      # Persisting apply spec for VMs that were introduced before we started
      # persisting it on apply itself (this is for cloudcheck purposes only)
      if vm_model.apply_spec.nil?
        # The assumption is that apply_spec <=> VM state
        vm_model.update(:apply_spec => state)
      end

      instance = vm_model.instance
      if instance
        disk_size = state['persistent_disk'].to_i
        persistent_disk = instance.persistent_disk

        # This is to support legacy deployments where we did not have
        # the disk_size specified.
        if disk_size != 0 && persistent_disk && persistent_disk.size == 0
          persistent_disk.update(:size => disk_size)
        end
      end
    end

    # Looks at every job instance in the deployment plan and binds it to the
    # instance database model (idle VM is also created in the appropriate
    # resource pool if necessary)
    # @return [void]
    def bind_unallocated_vms
      @deployment_plan.jobs_starting_on_deploy.each(&:bind_unallocated_vms)
    end

    def bind_instance_networks
      @deployment_plan.jobs_starting_on_deploy.each(&:bind_instance_networks)
    end

    def bind_links
      links_resolver = Bosh::Director::DeploymentPlan::LinksResolver.new(@deployment_plan, @logger)

      @event_log.begin_stage('Binding links', @deployment_plan.jobs.size)
      @deployment_plan.jobs.each do |job|
        @event_log.track(job.name) do
          links_resolver.resolve(job)
        end
      end
    end

    # Binds template models for each release spec in the deployment plan
    # @return [void]
    def bind_templates
      @deployment_plan.releases.each do |release|
        release.bind_templates
      end

      @deployment_plan.jobs.each do |job|
        job.validate_package_names_do_not_collide!
      end
    end

    # Binds properties for all templates in the deployment
    # @return [void]
    def bind_properties
      @deployment_plan.jobs.each do |job|
        job.bind_properties
      end
    end

    # Binds stemcell model for each stemcell spec in each resource pool in
    # the deployment plan
    # @return [void]
    def bind_stemcells
      @deployment_plan.resource_pools.each do |resource_pool|
        stemcell = resource_pool.stemcell

        if stemcell.nil?
          raise DirectorError,
                "Stemcell not bound for resource pool `#{resource_pool.name}'"
        end

        stemcell.bind_model(@deployment_plan)
      end
    end

    def bind_dns
      binder = DeploymentPlan::DnsBinder.new(@deployment_plan)
      binder.bind_deployment
    end

    def bind_job_renames
      @deployment_plan.instance_models.each do |instance_model|
        update_instance_if_rename(instance_model)
      end
    end

    private

    def update_instance_if_rename(instance_model)
      if @deployment_plan.rename_in_progress?
        old_name = @deployment_plan.job_rename['old_name']
        new_name = @deployment_plan.job_rename['new_name']

        if instance_model.job == old_name
          @logger.info("Renaming `#{old_name}' to `#{new_name}'")
          instance_model.update(:job => new_name)
        end
      end
    end
  end
end
