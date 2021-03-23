# frozen_string_literal: true

require "forwardable"
module Resque
  module Kubernetes
    # Handles manifests that need to be executed before running Jobs
    class PreJobHandler
      include Resque::Kubernetes::ManifestConformance
      extend Forwardable

      attr_reader :owner, :pre_manifests, :client
      private :owner, :pre_manifests

      def_delegators :client, :jobs_client, :pods_client, :misc_client, :default_namespace

      def initialize(owner, pre_manifests)
        @owner = owner
        @pre_manifests = pre_manifests
        @client = Resque::Kubernetes::Client.new
      end

      def process
        pre_manifests.each do |manifest_call|
          manifest = DeepHash.new.merge!(owner.send(manifest_call))
          ensure_namespace(manifest)

          resource = Kubeclient::Resource.new(manifest)
          misc_client.send(create_type(manifest).to_sym, resource)
        end
      end

      private

      def create_type(manifest)
        raise ArgumentError.new "missing manifest key :kind" unless manifest["kind"]
        "create_#{manifest['kind'].downcase}"
      end
    end
  end
end
