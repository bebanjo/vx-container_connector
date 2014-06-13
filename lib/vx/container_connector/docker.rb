require 'docker'
require 'excon'
require 'vx/common/spawn'
require 'net/ssh'

module Vx
  module ContainerConnector

    class Docker

      autoload :Spawner, File.expand_path("../docker/spawner", __FILE__)
      autoload :Default, File.expand_path("../docker/default", __FILE__)

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
          container = instrument("create_container", container_type: "docker", container_options: create_container_options) do
            ::Docker::Container.create create_container_options
          end

          instrumentation = {
            container_type:    "docker",
            container:         container.json,
            container_options: start_container_options,
          }

          with_retries ::Docker::Error::NotFoundError, Excon::Errors::SocketError, limit: 3, sleep: 3 do
            instrument("start_container", instrumentation) do
              container.start start_container_options
            end
          end

          instrumentation = {
            container_type:    "docker",
            container:         container.json,
            container_options: start_container_options,
          }

          begin
            sleep 3
            yield container
          ensure
            instrument("kill_container", instrumentation) do
              container.kill
            end
          end

        rescue ::Net::SSH::AuthenticationFailed => e
          # In some situations we cannot connect because we don't have an IP for the container to connect to
          allocated_ip_address = instrumentation[:container]["NetworkSettings"]["IPAddress"] rescue ""
          if e.message =~ /Authentication failed for user #{@user}@$/ && allocated_ip_address == ""
            instrument("restarting_container", instrumentation)
            sleep 10
            retry
          end
        end

    end
  end
end
