# frozen_string_literal: true

module Resque
  module Kubernetes
    # Centralised opbject for cleint storage
    class Client
      def self.jobs_client
        @jobs_client ||= new.client("/apis/batch")
      end

      def self.pods_client
        @pods_client ||= new.client("")
      end

      def self.misc_client
        @misc_client ||= new.client("")
      end

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