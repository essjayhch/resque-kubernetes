# frozen_string_literal: true

require "kubeclient"

require_relative "manifest_conformance"

module Resque
  module Kubernetes
    # Spins up Kubernetes Jobs to run Resque workers.
    class JobsManager
      include Resque::Kubernetes::ManifestConformance

      attr_reader :owner
      private :owner

      def initialize(owner)
        @owner             = owner
        @default_namespace = "default"
      end

      def reap_finished_jobs
        finished_jobs.each do |job|
          begin
            Client.jobs_client.delete_job(job.metadata.name, job.metadata.namespace)
          rescue KubeException => e
            raise unless e.error_code == 404
          end
        end
      end

      def reap_finished_pods
        finished_pods.each do |pod|
          begin
            Client.pods_client.delete_pod(pod.metadata.name, pod.metadata.namespace)
          rescue KubeException => e
            raise unless e.error_code == 404
          end
        end
      end

      def apply_kubernetes_job
        manifest = DeepHash.new.merge!(owner.job_manifest)
        ensure_namespace(manifest)

        # Do not start job if we have reached our maximum count
        return if jobs_maxed?(manifest["metadata"]["name"], manifest["metadata"]["namespace"])

        adjust_manifest(manifest)

        job = Kubeclient::Resource.new(manifest)
        Client.jobs_client.create_job(job)
      end

      private

      def finished_jobs
        resque_jobs = Client.jobs_client.get_jobs(label_selector: "resque-kubernetes=job")
        resque_jobs.select { |job| job.spec.completions == job.status.succeeded }
      end

      def finished_pods
        resque_jobs = Client.pods_client.get_pods(label_selector: "resque-kubernetes=pod")
        resque_jobs.select do |pod|
          pod.status.phase == "Succeeded" && pod.status.containerStatuses.all? do |status|
            status.state.terminated.reason == "Completed"
          end
        end
      end

      def jobs_maxed?(name, namespace)
        resque_jobs = Client.jobs_client.get_jobs(
            label_selector: "resque-kubernetes=job,resque-kubernetes-group=#{name}",
            namespace:      namespace
        )
        running = resque_jobs.reject { |job| job.spec.completions == job.status.succeeded }
        running.size >= owner.max_workers
      end
    end
  end
end
