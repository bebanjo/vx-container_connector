require 'docker'
require 'excon'
require 'vx/common/spawn'
require 'net/ssh'

module Vx
  module ContainerConnector

    class Docker

      autoload :Spawner, File.expand_path("../docker/spawner", __FILE__)
      autoload :Default, File.expand_path("../docker/default", __FILE__)
      autoload :Errors, File.expand_path("../docker/errors", __FILE__)

      include Vx::Common::Spawn
      include ContainerConnector::Retriable
      include Instrument

      attr_reader :user, :password, :init, :image, :remote_dir

      def initialize(options = {})
        @user       = options[:user]       || "vexor"
        @password   = options[:password]   || "vexor"
        @init       = options[:init]       || %w{ /sbin/init --startup-event dockerboot }
        @image      = options[:image]      || "dmexe/vexor-precise-full"
        @remote_dir = options[:remote_dir] || "/home/#{user}"
      end

      def start(&block)
        start_container do |container|
          open_ssh_session(container, &block)
        end
      end

      def create_container_options
        Default.create_container_options.merge(
          'Cmd'   => init,
          'Image' => image,
          'Volumes' => { "#{remote_dir}/cache" => {}}
        )
      end

      def start_container_options
        Default.start_container_options.merge(
          'Binds' => [ "/opt/#{user}/worker/shared/cache/bundle:#{remote_dir}/cache:rw" ]
        )
      end

      private

        def open_ssh_session(container)
          host = Default.ssh_host || container.json['NetworkSettings']['IPAddress']

          ssh_options = {
            password:      password,
            port:          Default.ssh_port,
            paranoid:      false,
            forward_agent: false
          }

          instrumentation = {
            container_type: "docker",
            container:      container.json,
            ssh_host:       host
          }

          with_retries ::Net::SSH::AuthenticationFailed, Errno::ECONNREFUSED, Errno::ETIMEDOUT, limit: 10, sleep: 5 do
            instrument("starting_ssh_session", instrumentation)
            open_ssh(host, user, ssh_options) do |ssh|
              yield Spawner.new(container, ssh, remote_dir)
            end
          end
        end

        def start_container(&block)
          container = nil

          with_retries Timeout::Error, Fog::Errors::TimeoutError, limit: 3, sleep: 10 do
            container = instrument("create_container", container_type: "docker", container_options: create_container_options) do
              ::Docker::Container.create create_container_options
            end

            instrumentation = {
              container_type:    "docker",
              container:         container.json,
              container_options: start_container_options,
            }

            begin
              with_retries ::Docker::Error::NotFoundError, Excon::Errors::SocketError, limit: 3, sleep: 3 do
                instrument("start_container", instrumentation) do
                  container.start start_container_options

                  Errors.wait_for(10, 2) do
                    container.json['State']['Running'] && container.json['NetworkSettings']['IPAddress'] != ""
                  end
                end
              end
            rescue Errors::TimeoutError => e
              if container
                instrument("container_cannot_start", {container_type => "docker", container: container.json})
              end
            end
          end

          begin
            yield container
          ensure
            instrumentation = {
              container_type: "docker",
              container:      container.json
            }

            instrument("stop_container", instrumentation) do
              container.stop
            end
          end
        end

    end
  end
end
