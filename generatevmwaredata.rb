#!/usr/bin/env ruby

require 'fog'
require 'yaml'

vcenters = `cat /etc/virt-who.d/vmware  | grep "server" | awk -F= '{print $2}'`.split("\n")
username='username'
password="password"


mainhash = Hash.new do |hash,key|
    hash[key] = Hash.new
end

vcenters.each do |vcentername|
    vc = Fog::Compute.new(
        :provider => "vsphere",
        :vsphere_username => "#{username}",
        :vsphere_password => "#{password}",
        :vsphere_server => "#{vcentername}",
        :vsphere_expected_pubkey_hash => ""
    )
    dcs = vc.list_datacenters
    dcs.each do |dc|
        dcname = dc[:name].chomp
        cras = vc.raw_clusters(dc[:name])
        cras.each do |cluster|
            clustername = cluster[:name].chomp
            cluster.host.each do |host|
                hostname = host[:name].chomp
                cpucount = host.hardware.cpuInfo.numCpuPackages
                mainhash["#{hostname}"]["vcenter"] = vcentername
                mainhash["#{hostname}"]["datacenter"] = dcname
                mainhash["#{hostname}"]["cluster"] = clustername
                mainhash["#{hostname}"]["cpucount"] = cpucount
            end
        end
    end
end

File.open("vmwareclusters.yaml" ,'w') do |file|
    file.write mainhash.to_yaml
end
