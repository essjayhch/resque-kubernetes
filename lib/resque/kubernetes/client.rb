# frozen_string_literal: true

module Resque
  module Kubernetes
    # Centralised opbject for cleint storage
    class Client
      attr_accessor :default_namespace

      def initialize
        @default_namespace = "default"
      end

      def jobs_client
        client("/apis/batch")
      end

      def pods_client
        client("")
      end

      def misc_client
        client("")
      end

      private

      def client(scope)
        return RetriableClient.new(Resque::Kubernetes.kubeclient) if Resque::Kubernetes.kubeclient
        client = build_client(scope)
        RetriableClient.new(client) if client
      end

      def build_client(scope)
        context = ContextFactory.context
        return unless context
        @default_namespace = context.namespace if context.namespace

        Kubeclient::Client.new(context.endpoint + scope, context.version, context.options)
      end
    end
  end
end
