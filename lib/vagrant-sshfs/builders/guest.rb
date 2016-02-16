require "vagrant/util/subprocess"
module Vagrant
  module SshFS
    module Builders
      class Guest < Base
        private


        def port_already_forwarded?()
          port_forwarded = false
          machine.communicate.execute("ss -luntp", sudo: true) do |type, data|
            if type == :stdout
              if data.include?('127.0.0.1:10022')
                port_forwarded = true
                break
              end
            end
          end
          return port_forwarded
        end


        def remote_port_forward()
          if port_already_forwarded?()
            return
          end
          ssh_info = machine.ssh_info
          # set up remote port forwarding (-R) to forward port 10022
          # on the vagrant box to port 22 on the host. Run in the
          # background (-f) so the ssh call won't hang forever and
          # sleep forever so the tunnel will stay up.
          
          username = ssh_info[:username]
          port  = ssh_info[:port]
          host = ssh_info[:host]
          proxy_command = ssh_info[:proxy_command]
          id_file = ssh_info[:private_key_path][0]
         
          cmd = ['ssh']
          cmd.concat(
            [
              '-f', # Requests ssh to go to background just before command execution. 
              '-R 10022:localhost:22',
              '-o Compression=yes',
              '-o StrictHostKeyChecking=no',
              '-o ControlMaster=no',
              # '-o Ciphers=arcfour ', # TODO: evaluate usefullness of having this cypher?
              "-o IdentityFile=#{id_file}",
              "-l #{username}",
              "-p #{port}"
            ])
          
          cmd.push(%Q|-o ProxyCommand="#{proxy_command}"|) if proxy_command
            
          cmd.concat([host, "sleep infinity"])

          info("trying to forward remote ports.")
          info("cmd: #{cmd.join(" ")}")


          result = Vagrant::Util::Subprocess.execute(*cmd)
          if result.exit_code != 0
             print("bad stuff")
          end
        end

        def install_sshfs()
          if machine.communicate.test("type sshfs")
            return # already installed
          end
          
          info("Checking if we can install SSHFS inside the guest VM")
          if machine.communicate.test("type dnf")
            info("now installing SSHFS inside the guest VM")
            machine.communicate.execute("dnf install -y epel-release", sudo: true)
            machine.communicate.execute("dnf install -y sshfs", sudo: true)
          elsif machine.communicate.test("type yum")
            info("now installing SSHFS inside the guest VM")
            machine.communicate.execute("yum install -y epel-release", sudo: true)
            machine.communicate.execute("yum install -y sshfs", sudo: true)
          else
            error("SSHFS not found on the VM. Please install it first.")
          end

        end


        def unmount(target)
          if machine.communicate.execute("which fusermount", error_check: false) == 0
            machine.communicate.execute("fusermount -u -q #{target}", error_check: false)
          else
            machine.communicate.execute("umount #{target}", error_check: false)
          end
        end

        def create_dir_on_guest(dir)
          unless machine.communicate.test("test -d #{dir}")
            if machine.config.sshfs.sudo
              machine.communicate.execute("sudo su -c 'mkdir -p #{dir}'")
            else
              machine.communicate.execute("mkdir -p #{dir}")
            end
            info("created directory inside box", dir: dir)
          end
        end

        def is_mounted?(target)
          target = target.gsub(/\/+$/, '') # Remove trailing forward slashes
          mounted = false
          machine.communicate.execute("cat /proc/mounts") do |type, data|
            if type == :stdout
              data.each_line do |line|
                if line.split()[1] == target
                  mounted = true
                  break
                end
              end
            end
          end
          return mounted
        end
        

        def mount(src, target)
          source = File.expand_path(src) #messes up for windows
          source = src
          if is_mounted?(target)
            return
          end

          # create the target directory inside box:
          create_dir_on_guest(target)

          remote_port_forward()
          install_sshfs()

          # Some basic options for ssh:
          #  - Disable host key => no yes/no prompt
          #  - Connect to the specified port
          #  - allow_other - allows access to other users on guest
          # Some performance options from:
          # http://www.linux-magazine.com/Issues/2014/165/SSHFS-MUX
          #options+= '-o kernel_cache -o Ciphers=arcfour -o big_writes -o auto_cache -o cache_timeout=115200 -o attr_timeout=115200 -o entry_timeout=1200 -o max_readahead=90000 '
          #options+= '-o kernel_cache -o big_writes -o auto_cache -o cache_timeout=115200 -o attr_timeout=115200 -o entry_timeout=1200 -o max_readahead=90000 '
          #options+= '-o cache_timeout=3600 '
          
          cmd = [
            'sshfs',
            '-o StrictHostKeyChecking=no',
            "-p #{port}",
            '-o allow_other',
            '-o noauto_cache'
            ]

            
          # TODO: Ensure that SSH daemon is always running on the HOST.
          # TODO: Check it before `vagrant sshfs` attempts to mount the filesystem.

          # Grab password if necessary
          sshpass = password()
          echopipe = ""
          if sshpass
            echopipe= "echo " + sshpass + " | "
            cmd.push('-o password_stdin')
          end
          
          host_address = host
          if host_address.empty?
            info("Host not specified in the configuration file. Picking up localhost.")
            host_address = "localhost"
          end
          
          cmd.push("#{username}@#{host_address}:#{source} #{target}")
          
          sshfs_command = cmd.join(" ")
          exec_command = echopipe + sshfs_command
          
          info(exec_command)
          
          info("Exec Command: "+exec_command)
          status = machine.communicate.execute(
            exec_command,
            :sudo => true, :error_check => false)

          if status != 0
            error('not_mounted', src: source, target: target)
          end
        end

        def host
          machine.config.sshfs.host_addr
        end

        def port
          machine.config.sshfs.host_port ||= '22'
        end

        def username
          `whoami`.strip
        end

        def password
          # Check to see if user wants us to prompt them for password
          if machine.config.sshfs.password_prompt
            Shellwords.escape(ui.ask(i18n("ask.pass", :user => "#{username}@#{host}"), :echo => false))
          end
        end
      end
    end
  end
end
