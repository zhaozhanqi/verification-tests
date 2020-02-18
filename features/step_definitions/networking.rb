Given /^I run the ovs commands on the host:$/ do | table |
  ensure_admin_tagged
  _host = node.host
  ovs_cmd = table.raw.flatten.join
  if _host.exec_admin("ovs-vsctl --version")[:response].include? "Open vSwitch"
    logger.info("environment using rpm to launch openvswitch")
  elsif _host.exec_admin("docker ps")[:response].include? "openvswitch"
    logger.info("environment using docker to launch openvswith")
    container_id = _host.exec_admin("docker ps | grep openvswitch | cut -d' ' -f1")[:response].chomp
    ovs_cmd = "docker exec #{container_id} " + ovs_cmd
  elsif _host.exec_admin("runc list")[:response].include? "openvswitch"
    logger.info("environment using runc to launch openvswith")
    ovs_cmd = "runc exec openvswitch " + ovs_cmd
  # For 3.10 and runc env, should get containerID from the pod which landed on the node
  elsif env.version_ge("3.10", user: user)
    logger.info("OCP version >= 3.10 and environment may using runc to launch openvswith")
    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    container_id = ovs_pod.containers.first.id
    ovs_cmd = "runc exec #{container_id} " + ovs_cmd
  else
    raise "Cannot find the ovs command"
  end
  @result = _host.exec_admin(ovs_cmd)
end

Given /^I run ovs dump flows commands on the host$/ do
  step %Q/I run the ovs commands on the host:/, table(%{
    | ovs-ofctl dump-flows br0 -O openflow13 |
  })
end

Given /^the env is using multitenant network$/ do
  step 'the env is using one of the listed network plugins:', table([["multitenant"]])
end

Given /^the env is using networkpolicy plugin$/ do
  step 'the env is using one of the listed network plugins:', table([["networkpolicy"]])
end

Given /^the env is using multitenant or networkpolicy network$/ do
  step 'the env is using one of the listed network plugins:', table([["multitenant","networkpolicy"]])
end

Given /^the env is using one of the listed network plugins:$/ do |table|
  ensure_admin_tagged
  plugin_list = table.raw.flatten
  _admin = admin

  @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: '{{.pluginName}}')
  if @result[:success] then
    plugin_name = @result[:response].split("-").last
    unless plugin_list.include? plugin_name
      raise "the env network plugin is #{plugin_name} but expecting #{plugin_list}."
    end
  else
    _host = node.host rescue nil
    unless _host
      step "I store the schedulable nodes in the clipboard"
      _host = node.host
    end

    step %Q/I run the ovs commands on the host:/, table([[
      "ovs-ofctl dump-flows br0 -O openflow13 | grep table=253"
    ]])
    unless @result[:success]
      raise "failed to get table 253 from the open flows."
    end

    plugin_type = @result[:response][-17]
    case plugin_type
    when "0"
      plugin_name = "subnet"
    when "1"
      plugin_name = "multitenant"
    when "2"
      plugin_name = "networkpolicy"
    else
      raise "unknown network plugins."
    end
    logger.info("environment network plugin name: #{plugin_name}")

    unless plugin_list.include? plugin_name
      raise "the env network plugin is #{plugin_name} but expecting #{plugin_list}."
    end
  end
end

Given /^the network plugin is switched on the#{OPT_QUOTED} node$/ do |node_name|
  ensure_admin_tagged

  node_config = node(node_name).service.config
  config_hash = node_config.as_hash()
  if config_hash["networkConfig"]["networkPluginName"].include?("subnet")
    config_hash["networkConfig"]["networkPluginName"] = "redhat/openshift-ovs-multitenant"
    logger.info "Switch plguin to multitenant from subnet"
  else
    config_hash["networkConfig"]["networkPluginName"] = "redhat/openshift-ovs-subnet"
    logger.info "Switch plguin to subnet from multitenant/networkpolicy"
  end
  step "node config is merged with the following hash:", config_hash.to_yaml
end

Given /^the#{OPT_QUOTED} node network is verified$/ do |node_name|
  ensure_admin_tagged

  _node = node(node_name)
  _host = _node.host

  net_verify = proc {
    # to simplify the process, ping all node's tun0 IP including the node itself, even test env has only one node
    hostsubnet = BushSlicer::HostSubnet.list(user: admin)
    hostsubnet.each do | hostsubnet |
      dest_ip = IPAddr.new(hostsubnet.subnet).succ
      @result = _host.exec("ping -c 2 -W 2 #{dest_ip}")
      raise "failed to ping tun0 IP: #{dest_ip}" unless @result[:success]
    end
  }

  net_verify.call
  teardown_add net_verify
end

Given /^the#{OPT_QUOTED} node iptables config is verified$/ do |node_name|
  ensure_admin_tagged
  _node = node(node_name)
  _host = _node.host
  _admin = admin

  if env.version_lt("3.7", user: user)
    @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: "{{.network}}")
  else
    @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: '{{index .clusterNetworks 0 "CIDR"}}')
  end
  unless @result[:success]
    raise "Can not get clusternetwork resource!"
  end

  subnet = @result[:response]
  cb.clusternetwork = subnet

  @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default")
  if @result[:success]
    plugin_type = @result[:response]
  end

  if env.version_ge("3.9", user: user) && plugin_type.include?("openshift-ovs-networkpolicy")
    puts "OpenShift version >= 3.9 and uses networkpolicy plugin."
    filter_matches = [
      'INPUT -m comment --comment "Ensure that non-local NodePort traffic can flow" -j KUBE-NODEPORT-NON-LOCAL',
      'INPUT -m conntrack --ctstate NEW -m comment --comment "kubernetes externally-visible service portals" -j KUBE-EXTERNAL-SERVICES',
      'INPUT -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-ALLOW',
      'FORWARD -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-FORWARD',
      'FORWARD -i tun0 ! -o tun0 -m comment --comment "administrator overrides" -j OPENSHIFT-ADMIN-OUTPUT-RULES',
      'OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i docker0 -m comment --comment "from docker to localhost" -j ACCEPT',
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"attempted resend after connection close\" -m conntrack --ctstate INVALID -j DROP",
      "OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT",
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT"
    ]
    nat_matches = [
      "PREROUTING -m comment --comment \".*\" -j KUBE-SERVICES",
      "OUTPUT -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES",
      "POSTROUTING -m comment --comment \"rules for masquerading OpenShift traffic\" -j OPENSHIFT-MASQUERADE",
      "OPENSHIFT-MASQUERADE -s #{subnet} -m comment --comment \"masquerade .* traffic\" -j OPENSHIFT-MASQUERADE-2",
      "OPENSHIFT-MASQUERADE-2 -d #{subnet} -m comment --comment \"masquerade pod-to-external traffic\" -j RETURN",
      "OPENSHIFT-MASQUERADE-2 -j MASQUERADE"
    ]
  elsif env.version_ge("3.9", user: user)
    puts "OpenShift version >= 3.9 and uses multitenant or subnet plugin."
    filter_matches = [
      'INPUT -m comment --comment "Ensure that non-local NodePort traffic can flow" -j KUBE-NODEPORT-NON-LOCAL',
      'INPUT -m conntrack --ctstate NEW -m comment --comment "kubernetes externally-visible service portals" -j KUBE-EXTERNAL-SERVICES',
      'INPUT -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-ALLOW',
      'FORWARD -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-FORWARD',
      'FORWARD -i tun0 ! -o tun0 -m comment --comment "administrator overrides" -j OPENSHIFT-ADMIN-OUTPUT-RULES',
      'OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i docker0 -m comment --comment "from docker to localhost" -j ACCEPT',
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"attempted resend after connection close\" -m conntrack --ctstate INVALID -j DROP",
      "OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT",
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT"
    ]
    nat_matches = [
      "PREROUTING -m comment --comment \".*\" -j KUBE-SERVICES",
      "OUTPUT -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES",
      "POSTROUTING -m comment --comment \"rules for masquerading OpenShift traffic\" -j OPENSHIFT-MASQUERADE",
      "OPENSHIFT-MASQUERADE -s #{subnet} -m comment --comment \"masquerade .* traffic\" -j MASQUERADE",
    ]
  elsif env.version_ge("3.7", user: user) && plugin_type.include?("openshift-ovs-networkpolicy")
    puts "OpenShift version >= 3.7 and uses networkpolicy plugin."
    filter_matches = [
      'INPUT -m comment --comment "Ensure that non-local NodePort traffic can flow" -j KUBE-NODEPORT-NON-LOCAL',
      'INPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES',
      'INPUT -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-ALLOW',
      'FORWARD -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-FORWARD',
      'FORWARD -i tun0 ! -o tun0 -m comment --comment "administrator overrides" -j OPENSHIFT-ADMIN-OUTPUT-RULES',
      'OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i docker0 -m comment --comment "from docker to localhost" -j ACCEPT',
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"attempted resend after connection close\" -m conntrack --ctstate INVALID -j DROP",
      "OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT",
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT"
    ]
    nat_matches = [
      "PREROUTING -m comment --comment \".*\" -j KUBE-SERVICES",
      "OUTPUT -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES",
      "POSTROUTING -m comment --comment \"rules for masquerading OpenShift traffic\" -j OPENSHIFT-MASQUERADE",
      "OPENSHIFT-MASQUERADE -s #{subnet} -m comment --comment \"masquerade .* traffic\" -j OPENSHIFT-MASQUERADE-2",
      "OPENSHIFT-MASQUERADE-2 -d #{subnet} -m comment --comment \"masquerade pod-to-external traffic\" -j RETURN",
      "OPENSHIFT-MASQUERADE-2 -j MASQUERADE"
    ]
  elsif env.version_ge("3.7", user: user)
    puts "OpenShift version >= 3.7 and uses multitenant or subnet plugin."
    filter_matches = [
      'INPUT -m comment --comment "Ensure that non-local NodePort traffic can flow" -j KUBE-NODEPORT-NON-LOCAL',
      'INPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES',
      'INPUT -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-ALLOW',
      'FORWARD -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-FORWARD',
      'FORWARD -i tun0 ! -o tun0 -m comment --comment "administrator overrides" -j OPENSHIFT-ADMIN-OUTPUT-RULES',
      'OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i docker0 -m comment --comment "from docker to localhost" -j ACCEPT',
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"attempted resend after connection close\" -m conntrack --ctstate INVALID -j DROP",
      "OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT",
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT"
    ]
    nat_matches = [
      "PREROUTING -m comment --comment \".*\" -j KUBE-SERVICES",
      "OUTPUT -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES",
      "POSTROUTING -m comment --comment \"rules for masquerading OpenShift traffic\" -j OPENSHIFT-MASQUERADE",
      "OPENSHIFT-MASQUERADE -s #{subnet} -m comment --comment \"masquerade .* traffic\" -j MASQUERADE",
    ]
  elsif env.version_eq("3.6", user: user)
    puts "OpenShift version is 3.6"
    filter_matches = [
      'INPUT -m comment --comment "Ensure that non-local NodePort traffic can flow" -j KUBE-NODEPORT-NON-LOCAL',
      'INPUT -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-ALLOW',
      'OUTPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES',
      'FORWARD -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-FORWARD',
      'FORWARD -i tun0 ! -o tun0 -m comment --comment "administrator overrides" -j OPENSHIFT-ADMIN-OUTPUT-RULES',
      'OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT',
      'OPENSHIFT-FIREWALL-ALLOW -i docker0 -m comment --comment "from docker to localhost" -j ACCEPT',
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"attempted resend after connection close\" -m conntrack --ctstate INVALID -j DROP",
      "OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT",
      "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT"
    ]
    # different MASQUERADE rules for networkpolicy plugin and multitenant/subnet plugin, for example:
    #   with networkpolicy plugin it should be:
    #   "OPENSHIFT-MASQUERADE -s #{subnet} ! -d #{subnet} -m comment --comment "masquerade pod-to-external traffic" -j MASQUERADE"
    #   with multitenant or subnet plugin it should be:
    #   "OPENSHIFT-MASQUERADE -s #{subnet} -m comment --comment "masquerade pod-to-service and pod-to-external traffic" -j MASQUERADE"
    #   so use fuzzy matching in nat_matches.
    nat_matches = [
      'PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES',
      "OUTPUT -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES",
      'POSTROUTING -m comment --comment "kubernetes postrouting rules" -j KUBE-POSTROUTING',
      "OPENSHIFT-MASQUERADE -s #{subnet} .*--comment \"masquerade .*pod-to-external traffic\" -j MASQUERADE"
    ]
  else
    puts "OpenShift version < 3.6"
    filter_matches = [
      'INPUT -i tun0 -m comment --comment "traffic from(.*)" -j ACCEPT',
      'INPUT -p udp -m multiport --dports 4789 -m comment --comment "001 vxlan incoming" -j ACCEPT',
      'OUTPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES',
      "FORWARD -s #{subnet} -j ACCEPT",
      "FORWARD -d #{subnet} -j ACCEPT"
    ]
    nat_matches = [
      'PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES',
      'POSTROUTING -m comment --comment "kubernetes postrouting rules" -j KUBE-POSTROUTING',
      "POSTROUTING -s #{subnet} -j MASQUERADE"
    ]
  end

  iptables_verify = proc {
    @result = _host.exec_admin("systemctl status iptables")
    unless @result[:success] && @result[:response] =~ /Active:\s+?active/
      raise "The iptables deamon verification failed. The deamon is not active!"
    end

    @result = _host.exec_admin("iptables-save -t filter")
    filter_matches.each { |match|
      unless @result[:success] && @result[:response] =~ /#{match}/
        raise "The filter table verification failed!"
      end
    }

    @result = _host.exec_admin("iptables-save -t nat")
    nat_matches.each { |match|
      unless @result[:success] && @result[:response] =~ /#{match}/
        raise "The nat table verification failed!"
      end
    }
  }

  firewalld_verify = proc {
    @result = _host.exec_admin("systemctl status firewalld")
    unless @result[:success] && @result[:response] =~ /Active:\s+?active/
      raise "The firewalld deamon verification failed. The deamon is not active!"
    end

    @result = _host.exec_admin("iptables-save -t filter")
    filter_matches.each { |match|
      unless @result[:success] && @result[:response] =~ /#{match}/
        raise "The filter table verification failed!"
      end
    }

    @result = _host.exec_admin("iptables-save -t nat")
    nat_matches.each { |match|
      unless @result[:success] && @result[:response] =~ /#{match}/
        raise "The nat table verification failed!"
      end
    }
  }

  @result = _host.exec_admin("firewall-cmd --state")
  if @result[:success] && @result[:response] =~ /running/
    firewalld_verify.call
    logger.info "Cluster network #{subnet} saved into the :clusternetwork clipboard"
    teardown_add firewalld_verify
  else
    iptables_verify.call
    logger.info "Cluster network #{subnet} saved into the :clusternetwork clipboard"
    teardown_add iptables_verify
  end
end

Given /^the#{OPT_QUOTED} node standard iptables rules are removed$/ do |node_name|
  ensure_admin_tagged
  _node = node(node_name)
  _host = _node.host
  _admin = admin

  if env.version_lt("3.7", user: user)
    @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: "{{.network}}")
  else
    @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: '{{index .clusterNetworks 0 "CIDR"}}')
  end
  unless @result[:success]
    raise "Can not get clusternetwork resource!"
  end

  subnet = @result[:response]

  if env.version_lt("3.6", user: user)
    @result = _host.exec('iptables -D INPUT -p udp -m multiport --dports 4789 -m comment --comment "001 vxlan incoming" -j ACCEPT')
    raise "failed to delete iptables rule #1" unless @result[:success]
    @result = _host.exec('iptables -D INPUT -i tun0 -m comment --comment "traffic from SDN" -j ACCEPT')
    raise "failed to delete iptables rule #2" unless @result[:success]
    @result = _host.exec("iptables -D FORWARD -d #{subnet} -j ACCEPT")
    raise "failed to delete iptables rule #3" unless @result[:success]
    @result = _host.exec("iptables -D FORWARD -s #{subnet} -j ACCEPT")
    raise "failed to delete iptables rule #4" unless @result[:success]
    @result = _host.exec("iptables -t nat -D POSTROUTING -s #{subnet} -j MASQUERADE")
    raise "failed to delete iptables nat rule" unless @result[:success]
  else
    @resule = _host.exec('iptables -D OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT')
    raise "failed to delete iptables rule #1" unless @result[:success]
    @resule = _host.exec('iptables -D OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT')
    raise "failed to delete iptables rule #2" unless @result[:success]
    @resule = _host.exec("iptables -D OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT")
    raise "failed to delete iptables rule #3" unless @result[:success]
    @resule = _host.exec("iptables -D OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT")
    raise "failed to delete iptables rule #4" unless @result[:success]

    # compatible with different network plugin
    @result = _host.exec("iptables -S -t nat \| grep '#{subnet}' \| cut -d ' ' -f 2-")
    raise "failed to grep rule from the iptables nat table!" unless @result[:success]
    nat_rule = @result[:response]

    @resule = _host.exec("iptables -t nat -D #{nat_rule}")
    raise "failed to delete iptables nat rule" unless @result[:success]
  end
end

Given /^admin adds( and overwrites)? following annotations to the "(.+?)" netnamespace:$/ do |overwrite, netnamespace, table|
  ensure_admin_tagged
  _admin = admin
  _netnamespace = netns(netnamespace, env)
  _annotations = _netnamespace.annotations

  table.raw.flatten.each { |annotation|
    if overwrite
      @result = _admin.cli_exec(:annotate, resource: "netnamespace", resourcename: netnamespace, keyval: annotation, overwrite: true)
    else
      @result = _admin.cli_exec(:annotate, resource: "netnamespace", resourcename: netnamespace, keyval: annotation)
    end
    raise "The annotation '#{annotation}' was not successfully added to the netnamespace '#{netnamespace}'!" unless @result[:success]
  }

  teardown_add {
    current_annotations = _netnamespace.annotations(cached: false)

    unless current_annotations == _annotations
      current_annotations.keys.each do |annotation|
        @result = _admin.cli_exec(:annotate, resource: "netnamespaces", resourcename: netnamespace, keyval: "#{annotation}-")
        raise "The annotation '#{annotation}' was not removed from the netnamespace '#{netnamespace}'!" unless @result[:success]
      end

      if _annotations
        _annotations.each do |annotation, value|
          @result = _admin.cli_exec(:annotate, resource: "netnamespaces", resourcename: netnamespace, keyval: "#{annotation}=#{value}")
          raise "The annotation '#{annotation}' was not successfully added to the netnamespace '#{netnamespace}'!" unless @result[:success]
        end
      end
      # verify if the restoration process was succesfull
      current_annotations = _netnamespace.annotations(cached: false)
      unless current_annotations == _annotations
        raise "The restoration of netnamespace '#{netnamespace}' was not successfull!"
      end
    end
  }
end

Given /^the DefaultDeny policy is applied to the "(.+?)" namespace$/ do | project_name |
  ensure_admin_tagged

  if env.version_lt("3.6", user: user)
    @result = admin.cli_exec(:annotate, resource: "namespace", resourcename: project_name , keyval: 'net.beta.kubernetes.io/network-policy={"ingress":{"isolation":"DefaultDeny"}}')
    unless @result[:success]
      raise "Failed to apply the default deny annotation to specified namespace."
    end
  else
    @result = admin.cli_exec(:create, n: project_name , f: 'https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/networkpolicy/defaultdeny-v1-semantic.yaml')
    unless @result[:success]
      raise "Failed to apply the default deny policy to specified namespace."
    end
  end
end

Given /^the cluster network plugin type and version and stored in the clipboard$/ do
  ensure_admin_tagged
  _host = node.host
  
  step %Q/I run command on the node's sdn pod:/, table([["ovs-ofctl"],["dump-flows"],["br0"],["-O"],["openflow13"]])
  unless @result[:success]
    raise "Unable to execute ovs command successfully. Check your command."
  end
  of_note = @result[:response].partition('note:').last.chomp
  cb.net_plugin = {
    type: of_note[0,2],
    version: of_note[3,2]
  }
end

Given /^I wait for the networking components of the node to be terminated$/ do
  ensure_admin_tagged

  if env.version_ge("3.10", user: user)
    sdn_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first

    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first

    unless sdn_pod.nil?
      @result = sdn_pod.wait_till_not_ready(user, 3 * 60)
      unless @result[:success]
        logger.error(@result[:response])
        raise "sdn pod on the node did not die"
      end
    end

    unless ovs_pod.nil?
      @result = ovs_pod.wait_till_not_ready(user, 60)
      unless @result[:success]
        logger.error(@result[:response])
        raise "ovs pod on the node did not die"
      end
    end
  end
end

Given /^I wait for the networking components of the node to become ready$/ do
  ensure_admin_tagged

  if env.version_ge("3.10", user: user)
    sdn_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first

    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first

    @result = sdn_pod.wait_till_ready(user, 3 * 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "sdn pod on the node did not become ready"
    end
    cb.sdn_pod = sdn_pod

    @result = ovs_pod.wait_till_ready(user, 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "ovs pod on the node did not become ready"
    end
  end
end

Given /^I restart the openvswitch service on the node$/ do
  ensure_admin_tagged
  _host = node.host
  _admin = admin

  # For 3.10 version, should delete the ovs container to restart service
  if env.version_ge("3.10", user: user)
    logger.info("OCP version >= 3.10")
    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    @result = ovs_pod.ensure_deleted(user: _admin)
  else
    @result = _host.exec_admin("systemctl restart openvswitch")
  end

  unless @result[:success]
    raise "Fail to restart the openvswitch service"
  end
end

Given /^I restart the network components on the node( after scenario)?$/ do |after|
  ensure_admin_tagged
  _admin = admin
  _node = node

  restart_network = proc {
    # For 3.10 version, should delete the sdn pod to restart network components
    if env.version_ge("3.10", user: user)
      logger.info("OCP version >= 3.10")
      sdn_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: _admin) { |pod, hash|
        pod.node_name == _node.name
      }.first
      @result = sdn_pod.ensure_deleted(user: _admin)
    else
      step "the node service is restarted on the host"
    end
  }

  if after
    logger.info "Network components will be restarted after scenario on the node"
    teardown_add restart_network
  else
    restart_network.call
  end
end

Given /^I get the networking components logs of the node since "(.+)" ago$/ do | duration |
  ensure_admin_tagged

  if env.version_ge("3.10", user: user)
    sdn_pod = cb.sdn_pod || BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    @result = admin.cli_exec(:logs, resource_name: sdn_pod.name, n: "openshift-sdn", since: duration)
  else
    @result = node.host.exec_admin("journalctl -l -u kubelet --since \"#{duration} ago\" \| grep -E 'controller.go\|network.go'")
  end
end

Given /^the node's default gateway is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  step "I select a random node's host"
  cb_name = "gateway" unless cb_name
  @result = host.exec_admin("/sbin/ip route show default | awk '/default/ {print $3}'")

  cb[cb_name] = @result[:response].chomp
  unless IPAddr.new(cb[cb_name])
    raise "Failed to get the default gateway"
  end
  logger.info "The node's default gateway is stored in the #{cb_name} clipboard."
end


Given /^I store a random unused IP address from the reserved range to the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  cb_name = "valid_ip" unless cb_name
  step "the subnet for primary interface on node is stored in the clipboard"

  reserved_range = "#{cb.subnet_range}"

  validate_ip = IPAddr.new(reserved_range).to_range.to_a.shuffle.each { |ip|
    @result = step "I run command on the node's ovs pod:", table(
      "| ping | -c1 | -W2 | #{ip} |"
    )
    if @result[:exitstatus] == 0
      logger.info "The IP is in use."
    else
      logger.info "The random unused IP is stored in the #{cb_name} clipboard."
      cb[cb_name] = ip.to_s
      break
    end
  }
  raise "No available ip found in the range." unless IPAddr.new(cb[cb_name])
end

Given /^the valid egress IP is added to the#{OPT_QUOTED} node$/ do |node_name|
  ensure_admin_tagged
  step "I store a random unused IP address from the reserved range to the clipboard"
  node_name = node.name unless node_name

  @result = admin.cli_exec(:patch, resource: "hostsubnet", resource_name: "#{node_name}", p: "{\"egressIPs\":[\"#{cb.valid_ip}\"]}", type: "merge")
  raise "Failed to patch hostsubnet!" unless @result[:success]
  logger.info "The free IP #{cb.valid_ip} added to egress node #{node_name}."

  teardown_add {
    @result = admin.cli_exec(:patch, resource: "hostsubnet", resource_name: "#{node_name}", p: "{\"egressIPs\":[]}", type: "merge")
    raise "Failed to clear egress IP on node #{node_name}" unless @result[:success]
  }
end

# An IP echo service, which returns your source IP when you access it
# Used for returning the exact source IP when the packet being SNAT
Given /^an IP echo service is setup on the master node and the ip is stored in the#{OPT_SYM} clipboard$/ do | cb_name |
  ensure_admin_tagged

  host = env.master_hosts.first
  cb_name = "ipecho_ip" unless cb_name
  cb[cb_name] = host.local_ip

  @result = host.exec_admin("docker run --name ipecho -d -p 8888:80 docker.io/aosqe/ip-echo")
  raise "Failed to create the IP echo service." unless @result[:success]
  teardown_add {
    @result = host.exec_admin("docker rm -f ipecho")
    raise "Failed to delete the docker container." unless @result[:success]
  }
end


Given /^the multus is enabled on the cluster$/ do
  ensure_admin_tagged

  desired_multus_replicas = daemon_set('multus', project('openshift-multus')).replica_counters(user: admin)[:desired]
  available_multus_replicas = daemon_set('multus', project('openshift-multus')).replica_counters(user: admin)[:available]

  raise "Multus is not running correctly!" unless desired_multus_replicas == available_multus_replicas && available_multus_replicas != 0
end

Given /^the status of condition#{OPT_QUOTED} for network operator is :(.+)$/ do | type, status |
  ensure_admin_tagged
  expected_status = status

  if type == "Available"
    @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: "network", o: "jsonpath={.status.conditions[?(.type == \"Available\")].status}")
    real_status = @result[:response]
  elsif type == "Progressing"
    @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: "network", o: "jsonpath={.status.conditions[?(.type == \"Progressing\")].status}")
    real_status = @result[:response]
  elsif type == "Degraded"
    @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: "network", o: "jsonpath={.status.conditions[?(.type == \"Degraded\")].status}")
    real_status = @result[:response]
  else
    raise "Unknown condition type!"
  end

  raise "The status of condition #{type} is incorrect." unless expected_status == real_status
end

Given /^I run command on the#{OPT_QUOTED} node's sdn pod:$/ do |node_name, table|
  ensure_admin_tagged
  network_cmd = table.raw
  node_name ||= node.name
  _admin = admin
   @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}") 
  if @result[:response] == "OpenShiftSDN"
     sdn_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
       pod.node_name == node_name
     }.first
     cache_resources sdn_pod
     @result = sdn_pod.exec(network_cmd, as: admin)
  else
     ovnkube_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
       pod.node_name == node_name
     }.first
     cache_resources ovnkube_pod
     @result = ovnkube_pod.exec(network_cmd, as: admin)   
   end
  raise "Failed to execute network command!" unless @result[:success]
end
 
Given /^I restart the ovs pod on the#{OPT_QUOTED} node$/ do | node_name |
  ensure_admin_tagged
  ensure_destructive_tagged

  ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  @result = ovs_pod.ensure_deleted(user: admin)
  unless @result[:success]
    raise "Fail to delete the ovs pod"
  end
end

Given /^the default interface on nodes is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  _admin = admin
  step "I select a random node's host"
  cb_name ||= "interface"
  @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  if @result[:success] then
     networkType = @result[:response].strip
  end
  case networkType
  when "OVNKubernetes"
    step %Q/I run command on the node's ovnkube pod:/, table("| bash | -c | ip route show default |")
  when "OpenShiftSDN"
    step %Q/I run command on the node's sdn pod:/, table("| bash | -c | ip route show default |")
  else
    raise "unknown networkType"
  end 
  cb[cb_name] = @result[:response].split("\n").first.split(/\W+/)[7]
  logger.info "The node's default interface is stored in the #{cb_name} clipboard."
end

Given /^CNI vlan info is obtained on the#{OPT_QUOTED} node$/ do | node_name |
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  @result = host.exec_admin("/sbin/bridge vlan show")
  raise "Failed to execute bridge vlan show command" unless @result[:success]
end

Given /^the bridge interface named "([^"]*)" is deleted from the "([^"]*)" node$/ do |bridge_name, node_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  @result = host.exec_admin("/sbin/ip link delete #{bridge_name}")
  raise "Failed to delete bridge interface" unless @result[:success]
end

Given /^I run command on the#{OPT_QUOTED} node's ovnkube pod:$/ do |node_name, table|
  ensure_admin_tagged
  network_cmd = table.raw
  node_name ||= node.name

  ovnkube_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  cache_resources ovnkube_pod
  @result = ovnkube_pod.exec(network_cmd, as: admin)
  raise "Failed to execute network command!" unless @result[:success]
end

Given /^I run cmds on all ovs pods:$/ do | table |
  ensure_admin_tagged
  network_cmd = table.raw

  ovs_pods = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin)
  ovs_pods.each do |pod|
    @result = pod.exec(network_cmd, as: admin)
    raise "Failed to execute network command!" unless @result[:success]
  end
end

Given /^I run command on the#{OPT_QUOTED} node's ovs pod:$/ do |node_name, table|
  ensure_admin_tagged
  network_cmd = table.raw
  node_name ||= node.name

  ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
     pod.node_name == node_name
   }.first
  cache_resources ovs_pod
  @result = ovs_pod.exec(network_cmd, as: admin)
end

Given /^the subnet for primary interface on node is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  cb_name = "subnet_range" unless cb_name

  step "the default interface on nodes is stored in the clipboard"
  step "I run command on the node's sdn pod:", table(
    "| bash | -c | ip a show \"<%= cb.interface %>\" \\| grep inet \\| grep -v inet6  \\| awk '{print $2}' |"
  )
  raise "Failed to get the subnet range for the primary interface on the node" unless @result[:success]
  cb[cb_name] = @result[:response].chomp
  logger.info "Subnet range for the primary interface on the node is stored in the #{cb_name} clipboard."
end

Given /^the env is using "([^"]*)" networkType$/ do |network_type|
  ensure_admin_tagged
  _admin = admin
  @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  raise "the networkType is not #{network_type}" unless @result[:response] == network_type
end

Given /^the bridge interface named "([^"]*)" with address "([^"]*)" is added to the "([^"]*)" node$/ do |bridge_name,address,node_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  @result = host.exec_admin("ip link add #{bridge_name} type bridge;ip address add #{address} dev #{bridge_name};ip link set up #{bridge_name}")
  raise "Failed to add  bridge interface" unless @result[:success]
end

Given /^a DHCP service is configured for interface "([^"]*)" on "([^"]*)" node with address range and lease time as "([^"]*)"$/ do |br_inf,node_name,add_lease|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  dhcp_status_timeout = 30
  #Following will take dnsmasq backup and append curl contents to the dnsmasq config after
  @result = host.exec_admin("cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak;curl https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/multus-cni/dnsmasq_for_testbridge.conf | sed s/testbr1/#{br_inf}/g | sed s/88.8.8.100,88.8.8.110,24h/#{add_lease}/g > /etc/dnsmasq.conf;systemctl restart dnsmasq --now")
  raise "Failed to configure dnsmasq service" unless @result[:success]
  wait_for(dhcp_status_timeout) {
    if host.exec_admin("systemctl status dnsmasq")[:response].include? "running"
      logger.info("dnsmasq service is running fine")
    else
      raise "Failed to start dnsmasq service. Check you cluster health manually"
    end
  }
end

Given /^a DHCP service is deconfigured on the "([^"]*)" node$/ do |node_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  dhcp_status_timeout = 30
  #Copying original dnsmasq on to the modified one
  @result = host.exec_admin("systemctl stop dnsmasq;cp /etc/dnsmasq.conf.bak /etc/dnsmasq.conf;systemctl restart dnsmasq --now")
  raise "Failed to configure dnsmasq service" unless @result[:success]
  wait_for(dhcp_status_timeout) {
    if host.exec_admin("systemctl status dnsmasq")[:response].include? "running"
      logger.info("dnsmasq service is running fine")
      host.exec_admin("rm /etc/dnsmasq.conf.bak")
    else
      raise "Failed to start dnsmasq service. Check you cluster health manually"
    end
  }
end

Given /^the vxlan tunnel name of node "([^"]*)" is stored in the#{OPT_SYM} clipboard$/ do |node_name,cb_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  cb_name ||= "interface_name"
  @result = admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  if @result[:success] then
     networkType = @result[:response].strip
  end
  case networkType
  when "OVNKubernetes"
    inf_name = host.exec_admin("ifconfig | egrep -o '^k8[^:]+'")
    cb[cb_name] = inf_name[:response].split("\n")[0]
  when "OpenShiftSDN"
    cb[cb_name]="tun0"
  else
    raise "unable to find interface name or networkType"
  end
  logger.info "The tunnel interface name is stored in the #{cb_name} clipboard."
end

Given /^the vxlan tunnel address of node "([^"]*)" is stored in the#{OPT_SYM} clipboard$/ do |node_name,cb_address|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  cb_name ||= "interface_address"
  @result = admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  if @result[:success] then
     networkType = @result[:response].strip
  end
  case networkType
  when "OVNKubernetes"
    inf_name = host.exec_admin("ifconfig | egrep -o '^k8[^:]+'")
    @result = host.exec_admin("ifconfig #{inf_name[:response].split("\n")[0]}")
    cb[cb_address] = @result[:response].match(/\d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}/)[0]
  when "OpenShiftSDN"
    @result=host.exec_admin("ifconfig tun0")
    cb[cb_address] = @result[:response].match(/\d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}/)[0]
  else
    raise "unable to find interface address or networkType"
  end
  logger.info "The tunnel interface address is stored in the #{cb_address} clipboard."
end

Given /^the Internal IP of node "([^"]*)" is stored in the#{OPT_SYM} clipboard$/ do |node_name,cb_ipaddr|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  cb_ipaddr ||= "ip_address"
  @result = admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  if @result[:success] then
     networkType = @result[:response].strip
  end
  case networkType
  when "OVNKubernetes"
    step %Q/I run command on the node's ovnkube pod:/, table("| bash | -c | ip route show default |")
  when "OpenShiftSDN"
    step %Q/I run command on the node's sdn pod:/, table("| bash | -c | ip route show default |")
  else
    raise "unknown networkType"
  end
  def_inf = @result[:response].split("\n").first.split(/\W+/)[7]
  logger.info "The node's default interface is #{def_inf}"
  @result = host.exec_admin("ifconfig #{def_inf}")
  cb[cb_ipaddr]=@result[:response].match(/\d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}/)[0]
  logger.info "The Internal IP of node is stored in the #{cb_ipaddr} clipboard."
end

Given /^I store "([^"]*)" node's corresponding default networkType pod name in the#{OPT_SYM} clipboard$/ do |node_name,cb_pod_name|
  ensure_admin_tagged
  node_name ||= node.name
  _admin = admin
  cb_pod_name ||= "pod_name"
  @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  raise "Unable to find corresponding networkType pod name" unless @result[:success]
  if @result[:response] == "OpenShiftSDN"
     app="app=sdn"
     project_name="openshift-sdn"
  else
     app="app=ovnkube-node"
     project_name="openshift-ovn-kubernetes"
  end   
  cb[cb_pod_name] = BushSlicer::Pod.get_labeled(app, project: project(project_name, switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first.name
  logger.info "node's corresponding networkType pod name is stored in the #{cb_pod_name} clipboard."
end
