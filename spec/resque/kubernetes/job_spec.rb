# frozen_string_literal: true

require "spec_helper"

describe Resque::Kubernetes::Job do
  class ThingExtendingJob
    extend Resque::Kubernetes::Job

    def self.job_manifest
      default_manifest
    end

    def self.real_job_wo_kind
      {
          "api"      => "kubernetes.resque.int/api/fake",
          "metadata" => {"name" => "thing"},
          "spec"     => {

          }
      }
    end

    def self.real_job
      {
          "api"      => "kubernetes.resque.int/api/fake",
          "kind"     => "FakeResource",
          "metadata" => {"name" => "thing"},
          "spec"     => {

          }
      }
    end

    def self.default_manifest
      {
          "metadata" => {"name" => "thing"},
          "spec"     => {
              "template" => {
                  "spec" => {"containers" => [{}]}
              }
          }
      }
    end
  end

  class ThingIncludingJob
    include Resque::Kubernetes::Job

    def job_manifest
      default_manifest
    end

    def real_job_wo_kind
      {
          "api"      => "kubernetes.resque.int/api/fake",
          "metadata" => {"name" => "thing"},
          "spec"     => {

          }
      }
    end

    def real_job
      {
          "api"      => "kubernetes.resque.int/api/fake",
          "kind"     => "FakeResource",
          "metadata" => {"name" => "thing"},
          "spec"     => {

          }
      }
    end

    def default_manifest
      {
          "metadata" => {"name" => "thing"},
          "spec"     => {
              "template" => {
                  "spec" => {"containers" => [{}]}
              }
          }
      }
    end
  end

  class K8sStub < OpenStruct
    def initialize(hash)
      new_hash = hash.merge(metadata: {namespace: "default", name: "pod-#{Time.now.to_i}"})
      # Use JSON object_class to create a deep OpenStruct
      super(JSON.parse(new_hash.to_json, object_class: OpenStruct))
    end
  end

  let(:client) { spy("jobs client") }

  before do
    allow(Kubeclient::GoogleApplicationDefaultCredentials).to receive(:token).and_return("token")
    allow(Kubeclient::Client).to receive(:new).and_return(client)
  end

  shared_examples "before enqueue callback" do
    context "#before_enqueue_kubernetes_job" do
      let(:done_job)    { K8sStub.new(spec: {completions: 1}, status: {succeeded: 1}) }
      let(:working_job) { K8sStub.new(spec: {completions: 1}, status: {succeeded: 0}) }
      let(:done_pod) do
        K8sStub.new(status: {phase: "Succeeded", containerStatuses: [{state: {terminated: {reason: "Completed"}}}]})
      end
      let(:working_pod) { K8sStub.new(status: {phase: "Running"}) }
      let(:oom_pod) do
        K8sStub.new(status: {phase: "Succeeded", containerStatuses: [{state: {terminated: {reason: "OOMKilled"}}}]})
      end

      context "when Resque::Kubernetes.kubeclient is defined" do
        let(:client) { spy("custom client") }

        before do
          allow(Kubeclient::Client).to receive(:new).and_call_original
          allow(Resque::Kubernetes).to receive(:kubeclient).and_return(client)
        end

        it "uses the provided client" do
          expect(client).to receive(:get_jobs).at_least(:once).and_return([])
          expect(client).to receive(:get_pods).at_least(:once).and_return([])
          expect(client).to receive(:create_job)
          subject.before_enqueue_kubernetes_job
        end
      end

      context "when `enabled` is set to `true`" do
        before do
          allow(Resque::Kubernetes).to receive(:enabled).and_return(true)
        end

        it "calls kubernetes APIs" do
          expect_any_instance_of(Resque::Kubernetes::Client).to receive(:client).at_least(:once) do
            client
          end
          subject.before_enqueue_kubernetes_job
        end
      end

      context "when `enabled` is set to `false`" do
        before do
          allow(Resque::Kubernetes).to receive(:enabled).and_return(false)
        end

        it "does not make any kubernetes calls" do
          expect_any_instance_of(Resque::Kubernetes::Client).not_to receive(:client)
          subject.before_enqueue_kubernetes_job
        end
      end

      it "reaps any completed jobs matching our label" do
        jobs = [working_job, done_job]
        expect(client).to receive(:get_jobs).with(label_selector: "resque-kubernetes=job").and_return(jobs)
        expect(client).to receive(:delete_job).with(done_job.metadata.name, done_job.metadata.namespace)
        subject.before_enqueue_kubernetes_job
      end

      context "when a job is deleted while reaping completed jobs" do
        let(:error) { KubeException.new(404, 'job "thing" not found', spy("response")) }

        before do
          allow(client).to receive(:get_jobs).and_return([working_job, done_job])
          allow(client).to receive(:delete_job).and_raise(error)
        end

        it "gracefully continues" do
          expect { subject.before_enqueue_kubernetes_job }.not_to raise_error
        end
      end

      it "reaps all successfully completed pods of the jobs matching our label" do
        pods = [working_pod, done_pod, oom_pod]
        expect(client).to receive(:get_pods).with(label_selector: "resque-kubernetes=pod").and_return(pods)
        expect(client).to receive(:delete_pod).with(done_pod.metadata.name, done_pod.metadata.namespace)
        subject.before_enqueue_kubernetes_job
      end

      context "when a pod is deleted while reaping completed pods" do
        let(:error) { KubeException.new(404, 'pod "thing" not found', spy("response")) }

        before do
          allow(client).to receive(:get_pods).and_return([working_pod, done_pod])
          allow(client).to receive(:delete_pod).and_raise(error)
        end

        it "gracefully continues" do
          expect { subject.before_enqueue_kubernetes_job }.not_to raise_error
        end
      end

      shared_examples "max workers" do
        context "when the maximum number of matching, working jobs is met" do
          let(:workers) { 1 }

          before do
            allow(client).to receive(:get_jobs).and_return([working_job])
          end

          it "does not try to create a new job" do
            expect(Kubeclient::Resource).not_to receive(:new)
            subject.before_enqueue_kubernetes_job
          end
        end

        context "when more that maximum workers are running" do
          let(:workers) { 1 }

          before do
            allow(client).to receive(:get_jobs).and_return(
                [
                    working_job, K8sStub.new(spec: {completions: 1}, status: {succeeded: 0})
                ]
            )
          end

          it "does not try to create a new job" do
            expect(Kubeclient::Resource).not_to receive(:new)
            subject.before_enqueue_kubernetes_job
          end
        end

        context "when matching, completed jobs exist" do
          let(:workers) { 2 }

          before do
            allow(client).to receive(:get_jobs).and_return([done_job, working_job])
          end

          it "creates a new job using the provided job manifest" do
            expect(client).to receive(:create_job)
            subject.before_enqueue_kubernetes_job
          end
        end

        context "when more job workers can be launched" do
          let(:job) { double("job") }
          let(:workers) { 10 }

          before do
            allow(client).to receive(:get_jobs).and_return([])
            allow(Kubeclient::Resource).to receive(:new).and_return(job)
          end

          it "creates a new job using the provided job manifest" do
            expect(client).to receive(:create_job)
            subject.before_enqueue_kubernetes_job
          end

          it "labels the job and the pod" do
            manifest = hash_including(
                "metadata" => hash_including(
                    "labels" => hash_including(
                        "resque-kubernetes" => "job"
                    )
                ),
                "spec"     => hash_including(
                    "template" => hash_including(
                        "metadata" => hash_including(
                            "labels" => hash_including(
                                "resque-kubernetes" => "pod"
                            )
                        )
                    )
                )
            )
            expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
            subject.before_enqueue_kubernetes_job
          end

          it "label the job to group it based on the provided name in the manifest" do
            manifest = hash_including(
                "metadata" => hash_including(
                    "labels" => hash_including(
                        "resque-kubernetes-group" => "thing"
                    )
                )
            )
            expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
            subject.before_enqueue_kubernetes_job
          end

          it "updates the job name to make it unique" do
            manifest = hash_including(
                "metadata" => hash_including(
                    "name" => match(/^thing-[a-z0-9]{5}$/)
                )
            )
            expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
            subject.before_enqueue_kubernetes_job
          end

          context "when the restart policy is included" do
            before do
              manifest = subject.default_manifest.dup
              manifest["spec"]["template"]["spec"]["restartPolicy"] = "Always"
              allow(subject).to receive(:job_manifest).and_return(manifest)
            end

            it "retains it" do
              manifest = hash_including(
                  "spec" => hash_including(
                      "template" => hash_including(
                          "spec" => hash_including(
                              "restartPolicy" => "Always"
                          )
                      )
                  )
              )
              expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
              subject.before_enqueue_kubernetes_job
            end
          end

          context "when the restart policy is not set" do
            it "ensures it is set to OnFailure" do
              manifest = hash_including(
                  "spec" => hash_including(
                      "template" => hash_including(
                          "spec" => hash_including(
                              "restartPolicy" => "OnFailure"
                          )
                      )
                  )
              )
              expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
              subject.before_enqueue_kubernetes_job
            end
          end

          context "when INTERVAL environment is included" do
            before do
              manifest = subject.default_manifest.dup
              manifest["spec"]["template"]["spec"]["containers"][0]["env"] = [
                  {"name" => "INTERVAL", "value" => "5"}
              ]
              allow(subject).to receive(:job_manifest).and_return(manifest)
            end

            it "ensures it is set to 0" do
              manifest = hash_including(
                  "spec" => hash_including(
                      "template" => hash_including(
                          "spec" => hash_including(
                              "containers" => array_including(
                                  hash_including(
                                      "env" => array_including(
                                          hash_including("name" => "INTERVAL", "value" => "0")
                                      )
                                  )
                              )
                          )
                      )
                  )
              )
              expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
              subject.before_enqueue_kubernetes_job
            end
          end

          context "when INTERVAL environment is not set" do
            it "ensures it is set to 0" do
              manifest = hash_including(
                  "spec" => hash_including(
                      "template" => hash_including(
                          "spec" => hash_including(
                              "containers" => array_including(
                                  hash_including(
                                      "env" => array_including(
                                          hash_including("name" => "INTERVAL", "value" => "0")
                                      )
                                  )
                              )
                          )
                      )
                  )
              )
              expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
              subject.before_enqueue_kubernetes_job
            end
          end

          context "when the namespace is not included in the manifest" do
            context "and no value is provided by the authentication context" do
              it "sets it to 'default'" do
                manifest = hash_including(
                    "metadata" => hash_including(
                        "namespace" => "default"
                    )
                )
                expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
                subject.before_enqueue_kubernetes_job
              end
            end

            context "and the authentication context provides a namespace" do
              let(:context) do
                OpenStruct.new(
                    endpoint:  "https://127.0.0.0",
                    version:   "v1",
                    namespace: "space",
                    options:   {}
                )
              end

              before do
                allow(Resque::Kubernetes::ContextFactory).to receive(:context).and_return(context)
              end

              it "uses the context-provided namespace" do
                manifest = hash_including(
                    "metadata" => hash_including(
                        "namespace" => "space"
                    )
                )
                expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
                subject.before_enqueue_kubernetes_job
              end
            end
          end

          context "when the namespace is set" do
            before do
              manifest = subject.default_manifest.dup
              manifest["metadata"]["namespace"] = "staging"
              allow(subject).to receive(:job_manifest).and_return(manifest)
            end

            it "retains it" do
              manifest = hash_including(
                  "metadata" => hash_including(
                      "namespace" => "staging"
                  )
              )
              expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
              subject.before_enqueue_kubernetes_job
            end
          end

        end
      end

      shared_examples "pre-job-manifest" do
        let(:job) { double(:job) }
        around(:each) do |example|
          subject.class.pre_job_manifests pre_jobs
          example.run
          subject.class.pre_job_manifests []
        end

        context "when job has a pre-job manifest defined" do
          context "wjen the job does not have a 'kind' attribtue set" do
            let(:pre_jobs) { [:real_job_wo_kind] }

            it "attempts to call the job included but raises arguement error" do
              expect(subject).to receive(:real_job_wo_kind).and_call_original
              expect { subject.before_enqueue_kubernetes_job }.to raise_exception(ArgumentError)
            end
          end

          context "when the job has a 'kind' attribute set" do
            let(:pre_jobs) { [:real_job] }

            it "attempts to call the job included via the hook" do
              expect(subject).to receive(:real_job).and_call_original
              expect { subject.before_enqueue_kubernetes_job }.to_not raise_exception
            end
          end
        end

        context "when job has not got a pre-job manifest defined" do
          let(:pre_jobs) { [:no_job] }
          it "attempts to call jobs included via the hook" do
            expect(subject).to receive(:no_job).and_raise(StandardError)
            expect { subject.before_enqueue_kubernetes_job }.to raise_exception(StandardError)
          end
        end

        context "when the namespace is not included with the manifest" do
          let(:pre_jobs) { [:real_job] }
          context "and no value is provided by the authentication context" do
            it "sets it to 'default'" do
              manifest = hash_including(
                  "api"      => "kubernetes.resque.int/api/fake",
                  "metadata" => hash_including(
                      "namespace" => "default"
                  )
              )
              expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
              subject.before_enqueue_kubernetes_job
            end
          end
        end

        context "when job has a namespace set" do
          let(:pre_jobs) { [:real_job] }
          before do
            manifest = subject.real_job.dup
            manifest["metadata"]["namespace"] = "staging"
            allow(subject).to receive(:real_job).and_return(manifest)
          end

          it "retains it" do
            manifest = hash_including(
                "api"      => "kubernetes.resque.int/api/fake",
                "metadata" => hash_including(
                    "namespace" => "staging"
                )
            )
            expect(Kubeclient::Resource).to receive(:new).with(manifest).and_return(job)
            subject.before_enqueue_kubernetes_job
          end
        end
      end

      context "for pre-job manifest" do
        include_examples "pre-job-manifest"
      end

      context "for the gem-global max_workers setting" do
        before do
          allow(Resque::Kubernetes).to receive(:max_workers).and_return(workers)
        end

        include_examples "max workers"
      end

      context "for the job-specific max_workers setting" do
        before do
          allow(Resque::Kubernetes).to receive(:max_workers).and_return(0)
          allow(subject).to receive(:max_workers).and_return(workers)
        end

        include_examples "max workers"
      end
    end
  end

  context "Pure Resque" do
    subject { ThingExtendingJob }

    include_examples "before enqueue callback"
  end

  context "ActiveJob (backed by Resque)" do
    subject { ThingIncludingJob.new }

    include_examples "before enqueue callback"
  end

end
