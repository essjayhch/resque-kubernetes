# frozen_string_literal: true

module Resque
  module Kubernetes
    # Resque hook to autoscale Kubernetes Jobs for workers.
    #
    # To use with pure Resque, extend your Resque job class with this module
    # and then define a class method `job_manifest` that produces the
    # Kubernetes Job manifest.
    #
    # To use with ActiveJob, include this module in your ActiveJob class
    # and then define an instance method `job_manifest` that produces the
    # Kubernetes Job manifest.
    #
    # Example (pure Resque):
    #
    #     class ResourceIntensiveJob
    #       extend Resque::Kubernetes::Job
    #       class << self
    #         def perform
    #           # ... your existing code
    #         end
    #
    #         def job_manifest
    #           YAML.safe_load(
    #             <<~MANIFEST
    #             apiVersion: batch/v1
    #               kind: Job
    #               metadata:
    #                 name: worker-job
    #               spec:
    #                 template:
    #                   metadata:
    #                     name: worker-job
    #                   spec:
    #                     containers:
    #                     - name: worker
    #                       image: us.gcr.io/project-id/some-resque-worker
    #                       env:
    #                       - name: QUEUE
    #                         value: high-memory
    #             MANIFEST
    #           )
    #         end
    #       end
    #     end
    #
    # Example (ActiveJob backed by Resque):
    #
    #     class ResourceIntensiveJob < ApplicationJob
    #       include Resque::Kubernetes::Job
    #       def perform
    #         # ... your existing code
    #       end
    #
    #       def job_manifest
    #         YAML.safe_load(
    #           <<~MANIFEST
    #           apiVersion: batch/v1
    #             kind: Job
    #              metadata:
    #                name: worker-job
    #              spec:
    #                template:
    #                  metadata:
    #                    name: worker-job
    #                  spec:
    #                    containers:
    #                    - name: worker
    #                      image: us.gcr.io/project-id/some-resque-worker
    #                      env:
    #                      - name: QUEUE
    #                        value: high-memory
    #           MANIFEST
    #         )
    #       end
    #     end
    module Job
      def self.included(base)
        base.class.send(:define_method, :pre_manifests) do
          @pre_manifests
        end

        base.class.send(:define_method, :pre_job_manifests) do |hooks|
          raise NotImplementedError unless hooks.is_a?(Array) || hooks.is_nil?
          @pre_manifests = hooks
        end

        return unless base.respond_to?(:before_enqueue)

        base.before_enqueue :before_enqueue_kubernetes_job
      end

      def process_before_job_hooks(*_args)
        return unless self.class.pre_manifests
        pre_job_handler = PreJobHandler.new(self, self.class.pre_manifests)
        pre_job_handler.process
      end

      # A before_enqueue hook that adds worker jobs to the cluster.
      def before_enqueue_kubernetes_job(*args)
        return unless Resque::Kubernetes.enabled

        process_before_job_hooks(args)
        manager = JobsManager.new(self)
        manager.reap_finished_jobs
        manager.reap_finished_pods
        manager.apply_kubernetes_job
      end

      # The maximum number of workers to autoscale the job to.
      #
      # While the number of active Kubernetes Jobs is less than this number,
      # the gem will add new Jobs to auto-scale the workers.
      #
      # By default, this returns `Resque::Kubernetes.max_workers` from the gem
      # configuration. You may override this method to return any other value,
      # either as a simple integer or with some complex logic.
      #
      # Example:
      #    def max_workers
      #      # A simple integer
      #      105
      #    end
      #
      # Example:
      #    def max_workers
      #      # Scale based on time of day
      #      Time.now.hour < 8 ? 15 : 5
      #    end
      def max_workers
        Resque::Kubernetes.max_workers
      end
    end
  end
end
