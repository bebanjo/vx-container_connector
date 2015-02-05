require 'docker'
require 'excon'
require 'timeout'
require 'net/ssh'
require 'vx/lib/shell'

module Vx
  module Lib
    module Container

      class Docker

        autoload :Spawner, File.expand_path("../docker/spawner", __FILE__)

        include Lib::Shell
        include Lib::Container::Retriable

        attr_reader :user, :password, :init, :image, :remote_dir, :memory, :memory_swap

        def initialize(options = {})
          @user        = options[:user]        || "vexor"
          @password    = options[:password]    || "vexor"
          @init        = options[:init]        || %w{ /sbin/my_init }
          @image       = options[:image]       || "ubuntu"
          @remote_dir  = options[:remote_dir]  || "/home/#{user}"
          @memory      = options[:memory].to_i
          @memory_swap = options[:memory_swap].to_i
        end

        def start(&block)
          start_container do |container|
            open_ssh_session(container, &block)
          end
        end

        def create_container_options
          @create_container_options ||= {
            'Cmd'        => init,
            'Image'      => image,
            'Memory'     => memory,
            'MemorySwap' => memory_swap
          }
        end

        def start_container_options
          Default.start_container_options
        end

        private

          def open_ssh_session(container)
            host = container.json['NetworkSettings']['IPAddress']

            ssh_options = {
              password:      password,
              port:          22,
              paranoid:      false,
              forward_agent: false,
              timeout:       3,
            }

            ssh = with_retries ::Net::SSH::AuthenticationFailed, ::Errno::ECONNREFUSED, ::Errno::ETIMEDOUT, ::Timeout::Error, limit: 10, sleep: 3 do
              ::Net::SSH.start host, user, ssh_options
            end

            re = yield Spawner.new(container, ssh)
            ssh.shutdown!
            re
          end

          def start_container(&block)
            container =
              with_retries ::Docker::Error::TimeoutError, limit: 5, sleep: 3 do
                ::Docker::Container.create create_container_options
              end

            container.start start_container_options

            begin
              yield container
            ensure
              container.kill
              container.remove
            end
          rescue ::Net::SSH::AuthenticationFailed => e
            # In some situations we cannot connect because we don't have an IP for the container to connect to
            allocated_ip_address = container.json["NetworkSettings"]["IPAddress"] rescue ""
            if e.message =~ /Authentication failed for user$/ && allocated_ip_address == ""
              sleep 10
              retry
            end
          end
      end
    end
  end
end
