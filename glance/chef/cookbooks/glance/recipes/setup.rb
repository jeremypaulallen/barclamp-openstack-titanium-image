#
# Cookbook Name:: glance
# Recipe:: setup
#

include_recipe "#{@cookbook_name}::common"

Chef::Log.info(">>>>>> Glance: Setup Recipe")

# Retrieves virtual ip addresses from LoadBalancer
admin_vip = node[:haproxy][:admin_ip]
public_vip = node[:haproxy][:public_ip]

glance_path = "/opt/glance"
venv_path = node[:glance][:use_virtualenv] ? "#{glance_path}/.venv" : nil
venv_prefix = node[:glance][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil

directory "#{node[:glance][:working_directory]}/raw_images" do
  action :create
end

if node[:glance][:use_keystone]
  env_filter = " AND keystone_config_environment:keystone-config-#{node[:glance][:keystone_instance]}"
  keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
  if keystones.length > 0
    keystone = keystones[0]
    keystone = node if keystone.name == node.name
  else
    keystone = node
  end

  # key_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address
  key_ip = admin_vip 
  admin_token = "-I #{keystone["keystone"]["admin"]["username"]}"
  admin_token = "#{admin_token} -K #{keystone["keystone"]["admin"]["password"]}"
  admin_token = "#{admin_token} -T #{keystone["keystone"]["admin"]["tenant"]}"
  admin_token = "#{admin_token} -N http://#{key_ip}:#{keystone["keystone"]["api"]["api_port"]}/v2.0"
else
  admin_token = ""
end

my_ipaddress = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
port = node["glance"]["api"]["bind_port"]

glance_args = "-H #{my_ipaddress} -p #{port} #{admin_token}"

#
# Download and install AMIs
#
# XXX: This is not generic and only works with this one image.
# If the json file changes, we need to update this procedure.
#

### HA Deployment : Glance images upload has to be done from only one controller node  
# Retrieves glance proposal name to pick up the first glance node we find
service_name = node[:glance][:config][:environment]
proposal_name = service_name.split('-')
bcproposal = "bc-glance-"+proposal_name[2]

getrmip_db = data_bag_item('crowbar', bcproposal)
# Selects the first glance node among all Glance nodes 
glance_node1_host = getrmip_db["deployment"]["glance"]["elements"]["glance-server"][0]
my_hostname = node["hostname"]
if my_hostname.split(".").first == glance_node1_host.split(".").first
  # The code below will be executed only one since same images uploads from different machines should not happen at the same time

  (node[:glance][:images] or []).each do |image|
    #get the filename of the image
    filename = image.split('/').last
    remote_file image do
      source image
      path "#{node[:glance][:working_directory]}/raw_images/#{filename}"
      action :create_if_missing
      not_if do 
        ::File.exists?("#{node[:glance][:working_directory]}/raw_images/#{filename}.keep")
      end
    end
  end
  ruby_block "load glance images" do
    block do
      wait = true
      rawdir="#{node[:glance][:working_directory]}/raw_images"
      Dir.entries(rawdir).each do |name|
        next unless node[:glance][:images].map{|n|n.split('/').last}.member?(name)
        basename = name.split('-')[0..1].join('-')
        tmpdir = "#{rawdir}/#{basename}"
        Dir.mkdir("#{tmpdir}") unless File.exists?("#{tmpdir}")
        Chef::Log.info("Extracting #{name} into #{tmpdir}")
        ::Kernel.system("tar -zxf \"#{rawdir}/#{name}\" -C \"#{tmpdir}/\"")
        if wait
          ::Kernel.system("#{venv_prefix}glance #{glance_args} image-list")
          sleep 15
          wait = false
        end
        ids = Hash.new
        cmds = Hash.new
        # Yes, this is exceptionally stupid for now.  Eventually it will be smarter.
        [ ["kernel", "vmlinuz-virtual"],
          ["initrd", "loader" ],
          ["image", ".img"] ].each do |part|
          next unless image_part = Dir.glob("#{tmpdir}/*#{part[1]}").first
          cmd = "#{venv_prefix}glance #{glance_args} image-create --name #{basename}-#{part[0]} --public"
          case part[0]
          when "kernel" then cmd << " --disk-format aki --container-format aki"
          when "initrd" then cmd << " --disk-format ari --container-format ari"
          when "image"
            cmd << " --disk-format ami --container-format ami"
            cmd << " --property kernel_id=#{ids["kernel"]}" if ids["kernel"]
            cmd << " --property ramdisk_id=#{ids["initrd"]}" if ids["initrd"]
          end
          res = %x{#{venv_prefix}glance #{glance_args} image-list| grep #{basename}-#{part[0]} 2>&1}
          if res.nil? || res.empty?
            Chef::Log.info("Loading #{image_part} for #{basename}-#{part[0]}")
            res = %x{#{cmd} < "#{image_part}"}
          else
            Chef::Log.info("#{basename}-#{part[0]} already loaded.")
          end
          ids[part[0]] = res.match(/([0-9a-f]+-){4}[0-9a-f]+/)
        end
        ::Kernel.system("rm -rf \"#{tmpdir}\"")
        File.truncate("#{rawdir}/#{name}",0)
        File.rename("#{rawdir}/#{name}","#{rawdir}/#{name}.keep")
      end
    end
  end
end
