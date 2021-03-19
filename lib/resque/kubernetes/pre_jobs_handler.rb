# frozen_string_literal: true

module Resque
  module Kubernetes
    # Handles manifests that need to be executed before running Jobs
    class PreJobHandler
      include Resque::Kubernetes::ManifestConformance

      attr_reader :owner, :pre_manifests
      private :owner, :pre_manifests

      def initialize(owner, pre_manifests)
        @owner = owner
        @default_namespace = "default"
        @pre_manifests = pre_manifests
      end

      def process
        pre_manifests.each do |manifest_call|
          manifest = DeepHash.new.merge!(owner.send(manifest_call))
          ensure_namespace(manifest)

          resource = Kubeclient::Resource.new(manifest)
          Client.misc_client.send("create_#{type(manifest)}".to_sym, resource)
        end
      end

      private

      def type(manifest)
        manifest[:kind].to_lower
      end
    end
  end
end
