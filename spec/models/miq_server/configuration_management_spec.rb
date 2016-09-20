describe MiqServer, "::ConfigurationManagement" do
  describe "#get_config" do
    shared_examples_for "#get_config" do
      it "with no changes in the database" do
        config = miq_server.get_config("vmdb")
        expect(config).to be_kind_of(VMDB::Config)
        expect(config.config.fetch_path(:api, :token_ttl)).to eq("10.minutes")
      end

      it "with changes in the database" do
        miq_server.settings_changes = [
          FactoryGirl.create(:settings_change, :key => "/api/token_ttl", :value => "2.minutes")
        ]
        Settings.reload!

        config = miq_server.get_config("vmdb")
        expect(config).to be_kind_of(VMDB::Config)
        expect(config.config.fetch_path(:api, :token_ttl)).to eq("2.minutes")
      end
    end

    context "local server" do
      let(:miq_server) { EvmSpecHelper.local_miq_server }

      before { stub_local_settings(miq_server) }

      include_examples "#get_config"
    end

    context "remote server" do
      let(:miq_server) { EvmSpecHelper.remote_miq_server }

      before { stub_local_settings(nil) }

      include_examples "#get_config"
    end
  end

  context "ConfigurationManagementMixin" do
    let(:miq_server) { FactoryGirl.create(:miq_server) }

    describe "#settings_for_resource" do
      it "returns the resource's settings" do
        settings = {:some_thing => [1, 2, 3]}
        stub_settings(settings)
        expect(miq_server.settings_for_resource.to_hash).to eq(settings)
      end
    end

    describe "#add_settings_for_resource" do
      it "sets the specified settings" do
        settings = {:some_test_setting => {:setting => 1}}
        expect(miq_server).to receive(:reload_all_server_settings)

        miq_server.add_settings_for_resource(settings)

        expect(Vmdb::Settings.for_resource(miq_server).some_test_setting.setting).to eq(1)
      end
    end

    describe "#reload_all_server_settings" do
      it "queues #reload_settings for the started servers" do
        FactoryGirl.create(:miq_server, :status => "started")

        miq_server.reload_all_server_settings

        expect(MiqQueue.count).to eq(1)
        message = MiqQueue.first
        expect(message.instance_id).to eq(miq_server.id)
        expect(message.method_name).to eq("reload_settings")
      end
    end
  end
end
