describe Job do
  context "With a single scan job," do
    before(:each) do
      @server1 = EvmSpecHelper.local_miq_server(:is_master => true)
      @server2 = FactoryGirl.create(:miq_server, :zone => @server1.zone)

      @miq_server = EvmSpecHelper.local_miq_server(:is_master => true)
      @zone = @miq_server.zone
      @ems        = FactoryGirl.create(:ems_vmware, :zone => @zone, :name => "Test EMS")
      @host       = FactoryGirl.create(:host)

      @worker = FactoryGirl.create(:miq_worker, :miq_server_id => @miq_server.id)
      @schedule_worker_settings = MiqScheduleWorker.worker_settings

      @vm       = FactoryGirl.create(:vm_vmware, :ems_id => @ems.id, :host_id => @host.id)
      @job      = @vm.raw_scan
    end

    context "where job is dispatched but never started" do
      before(:each) do
        @job.update_attribute(:dispatch_status, "active")

        Timecop.travel 5.minutes

        Job.check_jobs_for_timeout
      end

      after(:each) do
        Timecop.return
      end

      context "after queue message is processed" do
        before(:each) do
          @msg = MiqQueue.get(:role => "smartstate", :zone => @zone.name)
          status, message, result = @msg.deliver
          @msg.delivered(status, message, result)

          @job.reload
        end

        it "should queue a timeout job if one not already on there" do
          expect { @job.timeout! }.to change { MiqQueue.count }.by(1)
        end

        it "should be timed out after 5 minutes" do
          $log.info("@job: #{@job.inspect}")
          expect(@job.state).to eq("finished")
          expect(@job.status).to eq("error")
          expect(@job.message.starts_with?("job timed out after")).to be_truthy
        end
      end

      it "should not queue a timeout job if one is already on there" do
        expect { @job.timeout! }.not_to change { MiqQueue.count }
      end

      it "should queue a timeout job if one is there, but it is failed" do
        MiqQueue.first.update_attributes(:state => MiqQueue::STATE_ERROR)
        expect { @job.timeout! }.to change { MiqQueue.count }.by(1)
      end
    end

    context "where job is for a repository VM (no zone)" do
      before(:each) do
        @job.update_attributes(:state => "scanning", :dispatch_status => "active", :zone => nil)

        Timecop.travel 5.minutes

        Job.check_jobs_for_timeout

        @msg = MiqQueue.get(:role => "smartstate", :zone => @zone.name)
        status, message, result = @msg.deliver
        @msg.delivered(status, message, result)

        @job.reload
      end

      after(:each) do
        Timecop.return
      end

      it "should be timed out after 5 minutes" do
        $log.info("@job: #{@job.inspect}")
        expect(@job.state).to eq("finished")
        expect(@job.status).to eq("error")
        expect(@job.message.starts_with?("job timed out after")).to be_truthy
      end
    end

    context "where job is for a VM that disappeared" do
      before(:each) do
        @job.update_attributes(:state => "scanning", :dispatch_status => "active", :zone => nil)

        @vm.destroy

        Timecop.travel 5.minutes

        Job.check_jobs_for_timeout

        @msg = MiqQueue.get(:role => "smartstate", :zone => @zone.name)
        status, message, result = @msg.deliver
        @msg.delivered(status, message, result)

        @job.reload
      end

      after(:each) do
        Timecop.return
      end

      it "should be timed out after 5 minutes" do
        $log.info("@job: #{@job.inspect}")
        expect(@job.state).to eq("finished")
        expect(@job.status).to eq("error")
        expect(@job.message.starts_with?("job timed out after")).to be_truthy
      end
    end

    context "where 2 VMs in 2 Zones have an EVM Snapshot" do
      before(:each) do
        scan_type   = nil
        build       = '12345'
        description = "Snapshot for scan job: #{@job.guid}, EVM Server build: #{build} #{scan_type} Server Time: #{Time.now.utc.iso8601}"
        @snapshot = FactoryGirl.create(:snapshot, :vm_or_template_id => @vm.id, :name => 'EvmSnapshot', :description => description)

        @zone2     = FactoryGirl.create(:zone)
        @ems2      = FactoryGirl.create(:ems_vmware, :zone => @zone2, :name => "Test EMS 2")
        @vm2       = FactoryGirl.create(:vm_vmware, :ems_id => @ems2.id)
        @job2      = @vm2.raw_scan
        @job2.zone = @zone2.name
        description = "Snapshot for scan job: #{@job2.guid}, EVM Server build: #{build} #{scan_type} Server Time: #{Time.now.utc.iso8601}"
        @snapshot2 = FactoryGirl.create(:snapshot, :vm_or_template_id => @vm2.id, :name => 'EvmSnapshot', :description => description)
      end

      it "should create proper AR relationships" do
        expect(@snapshot.vm_or_template).to eq(@vm)
        expect(@vm.snapshots.first).to eq(@snapshot)
        expect(@vm.ext_management_system).to eq(@ems)
        expect(@ems.vms.first).to eq(@vm)

        expect(@snapshot2.vm_or_template).to eq(@vm2)
        expect(@vm2.snapshots.first).to eq(@snapshot2)
        expect(@vm2.ext_management_system).to eq(@ems2)
        expect(@ems2.vms.first).to eq(@vm2)
      end

      it "should be able to find Job from Evm Snapshot" do
        job_guid, ts = Snapshot.parse_evm_snapshot_description(@snapshot.description)
        expect(Job.find_by(:guid => job_guid)).to eq(@job)

        job_guid, ts = Snapshot.parse_evm_snapshot_description(@snapshot2.description)
        expect(Job.find_by(:guid => job_guid)).to eq(@job2)
      end

      context "where job is not found and the snapshot timestamp is less than an hour old with default job_not_found_delay" do
        before(:each) do
          @job.destroy
          Job.check_for_evm_snapshots
        end

        it "should not create delete snapshot queue message" do
          assert_no_queue_message
        end
      end

      context "where job is not found and the snapshot timestamp is less than an hour old with job_not_found_delay from worker settings" do
        before(:each) do
          @job.destroy
          Job.check_for_evm_snapshots(@schedule_worker_settings[:evm_snapshot_delete_delay_for_job_not_found])
        end

        it "should not create delete snapshot queue message" do
          assert_no_queue_message
        end
      end

      context "where job is not found and the snapshot timestamp is more than an hour old with job_not_found_delay from worker settings" do
        before(:each) do
          @job.destroy
          Timecop.travel 61.minutes
          Job.check_for_evm_snapshots(@schedule_worker_settings[:evm_snapshot_delete_delay_for_job_not_found])
        end

        after(:each) do
          Timecop.return
        end

        it "should create delete snapshot queue message" do
          assert_queue_message
        end
      end

      context "where job is not found and job_not_found_delay passed with 5 minutes and the snapshot timestamp is more than an 5 minutes old" do
        before(:each) do
          @job.destroy
          Timecop.travel 6.minutes
          Job.check_for_evm_snapshots(5.minutes)
        end

        after(:each) do
          Timecop.return
        end

        it "should create delete snapshot queue message" do
          assert_queue_message
        end
      end

      context "where job is not found and the snapshot timestamp is nil" do
        before(:each) do
          @job.destroy
          @snapshot.update_attribute(:description, "Foo")
          Job.check_for_evm_snapshots
        end

        it "should create delete snapshot queue message" do
          assert_queue_message
        end
      end

      context "where job is active" do
        before(:each) do
          @job.update_attribute(:state, "active")
          Job.check_for_evm_snapshots
        end

        it "should not create delete snapshot queue message" do
          assert_no_queue_message
        end
      end

      context "where job is finished" do
        before(:each) do
          @job.update_attribute(:state, "finished")
          Job.check_for_evm_snapshots
        end

        it "should create delete snapshot queue message" do
          assert_queue_message

          Job.check_for_evm_snapshots

          assert_queue_message
        end
      end
    end

    context "where scan jobs exist for both vms and container images" do
      before(:each) do
        @ems_k8s = FactoryGirl.create(
          :ems_kubernetes, :hostname => "test.com", :zone => @zone, :port => 8443,
          :authentications => [AuthToken.new(:name => "test", :type => 'AuthToken', :auth_key => "a secret")]
        )
        @image = FactoryGirl.create(
          :container_image, :ext_management_system => @ems_k8s, :name => 'test',
          :image_ref => "docker://3629a651e6c11d7435937bdf41da11cf87863c03f2587fa788cf5cbfe8a11b9a"
        )
        @image_scan_job = @image.ext_management_system.raw_scan_job_create(@image.class, @image.id)
      end

      context "#target_entity" do
        it "returns the job target" do
          expect(@job.target_entity).to eq(@vm)
          expect(@image_scan_job.target_entity).to eq(@image)
        end
      end

      context "#timeout_adjustment" do
        it "returns the correct adjusment" do
          expect(@job.timeout_adjustment).to eq(1)
          expect(@image_scan_job.timeout_adjustment).to eq(1)
        end
      end
    end
  end

  context "before_destroy callback" do
    before(:each) do
      @job = Job.create_job("VmScan", :name => "Hello, World!")
    end

    it "allows to delete not active job" do
      expect(Job.count).to eq 1
      @job.destroy
      expect(Job.count).to eq 0
    end

    it "doesn't allows to delete active job" do
      @job.update_attributes!(:state => "Scanning")
      expect(Job.count).to eq 1
      @job.destroy
      expect(Job.count).to eq 1
    end
  end

  describe "#attributes_log" do
    it "returns attributes for logging" do
      job = Job.create_job("VmScan", :name => "Hello, World!")
      expect(job.attributes_log).to include("VmScan", "Hello, World!", job.guid)
    end
  end

  context "belongs_to task" do
    before(:each) do
      @job = Job.create_job("VmScan", :name => "Hello, World!")
      @task = MiqTask.find_by(:name => "Hello, World!")
    end

    describe ".create_job" do
      it "creates job and corresponding task with the same name" do
        expect(@job.miq_task_id).to eq @task.id
      end
    end

    describe "#attributes_for_task" do
      it "returns hash with job's attributes to use for syncronization with linked task" do
        expect(@job.attributes_for_task).to include(
          :status        => @job.status.try(:capitalize),
          :state         => @job.state.try(:capitalize),
          :name          => @job.name,
          :message       => @job.message,
          :userid        => @job.userid,
          :miq_server_id => @job.miq_server_id,
          :context_data  => @job.context,
          :zone          => @job.zone,
          :started_on    => @job.started_on
        )
      end
    end

    context "after_update_commit callback calls" do
      describe "#update_linked_task" do
        it "executes when 'after_update_commit' callbacke triggered" do
          expect(@job).to receive(:update_linked_task)
          @job.save
        end

        it "updates 'context_data' attribute of miq_task if job's 'context' attribute was updated" do
          @job.update_attributes(:context => "some new context")
          expect(@task.reload.context_data).to eq "some new context"
        end

        it "updates 'started_on' attribute of miq_task if job's 'started_on' attribute was updated" do
          expect(@task.started_on).to be nil
          time = Time.new.utc.change(:usec => 0)
          @job.update_attributes(:started_on => time)
          expect(@task.reload.started_on).to eq time
        end

        it "updates 'zone' attribute of miq_task if job's 'zone' attribute updated" do
          @job.update_attributes(:zone => "Some Special Zone")
          expect(@task.reload.zone).to eq "Some Special Zone"
        end

        it "updates 'message' attribute of miq_task if job's 'message' attribute was updated" do
          @job.update_attributes(:message => "Some custom message for job")
          expect(@task.reload.message).to eq "Some custom message for job"
        end

        it "updates 'status' attribute of miq_task if job's 'status' attribute was updated" do
          @job.update_attributes(:status => "Custom status for job")
          expect(@task.reload.status).to eq "Custom status for job"
        end

        it "updates 'state' attribute of miq_task if job's 'state' attribute was updated" do
          @job.update_attributes(:state => "any status to trigger state update")
          expect(@task.reload.state).to eq "Any status to trigger state update"
        end
      end
    end
  end

  private

  def assert_queue_message
    expect(MiqQueue.count).to eq(1)
    q = MiqQueue.first
    expect(q.instance_id).to eq(@vm.id)
    expect(q.class_name).to eq(@vm.class.name)
    expect(q.method_name).to eq("remove_evm_snapshot")
    expect(q.args).to eq([@snapshot.id])
    expect(q.role).to eq("ems_operations")
    expect(q.zone).to eq(@zone.name)
  end

  def assert_no_queue_message
    expect(MiqQueue.count).to eq(0)
  end
end
