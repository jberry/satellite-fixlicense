#!/usr/bin/env ruby

require 'optparse'
require 'yaml'
require 'apipie-bindings'
require 'highline/import'
require 'csv'

class Hash
    def deep_find(key)
        key?(key) ? self[key] : self.values.inject(nil) {|memo, v| memo ||= v.deep_find(key) if v.respond_to?(:deep_find) }
    end
end

@defaults = {
    :noop       => false,
    :uri        => 'https://localhost/',
    :timeout    => 300,
    :user       => 'admin',
    :pass       => nil,
    :org        => 1,
    :fixvmware  => true,
    :fixphysical => true,
    :fixguests  => true,
    :debug      => false,
    :delete_unmapped_licenses    => true,
}

@options = {
    :yamlfile  => 'fixlicenses.yaml',
}

optparse = OptionParser.new do |opts|
    opts.banner = "Usage: #{opts.program_name} ACTION [options]"
    opts.version = "0.1"

    opts.separator ""
    opts.separator "#{opts.summary_indent}ACTION can be any of [fix,test]"
    opts.separator ""

    opts.on("-U", "--uri=URI", "URI to the Satellite") do |u|
        @options[:uri] = u
    end
    opts.on("-t", "--timeout=TIMEOUT", "Timeout value in seconds for any API calls. -1 means never timeout") do |t|
        @options[:timeout] = t
    end
    opts.on("-u", "--user=USER", "User to log in to Satellite") do |u|
        @options[:user] = u
    end
    opts.on("-p", "--pass=PASS", "Password to log in to Satellite") do |p|
        @options[:pass] = p
    end
    opts.on("-o", "--organization-id=ID", "ID of the Organization to clean up") do |o|
        @options[:org] = o
    end
    opts.on("-c", "--config=FILE", "configuration in YAML format") do |c|
        @options[:yamlfile] = c
    end
    opts.on("-n", "--noop", "do not actually execute anything") do
        @options[:noop] = true
    end
    opts.on("--skipvmware", "Skip vmware fixes") do
        @options[:fixvmware] = false
    end
    opts.on("--skipphysical", "Skip physical fixes") do
        @options[:fixphysical] = false
    end
    opts.on("--skipguests", "Skip guest fixes") do
        @options[:fixguests] = false
    end
    opts.on("--debug", "Debug output") do
        @options[:debug] = true
    end
    opts.on("--vmwareyaml=FILE", "YAML file containing vmware clusters") do |v|
        @options[:vmwareyaml] = v
    end
    opts.on("--licensecsv=FILE", "CSV file for licenses") do |l|
        @options[:licensecsv] = l
    end
end
optparse.parse!

if ARGV.empty?
    puts optparse.help
    exit
end

@yaml = YAML.load_file(@options[:yamlfile])

if @yaml.has_key?(:settings) and @yaml[:settings].is_a?(Hash)
    @yaml[:settings].each do |key,val|
        if not @options.has_key?(key)
            @options[key] = val
        end
    end
end

@crashed = Array.new
@errors = Array.new
@badreg = Array.new
@missingvhost = Array.new
@missinglicenses = Array.new
@removedlicenses = Array.new
@vhosts = Array.new
fixed = Array.new


@defaults.each do |key,val|
    if not @options.has_key?(key)
        @options[key] = val
    end
end

if not @options[:user]
    @options[:user] = ask('Satellite username: ')
end

if not @options[:pass]
    @options[:pass] = ask('Satellite password: ') { |q| q.echo = false }
end

@vmwaredata = YAML.load_file(@options[:vmwareyaml])
@licensehash = Hash.new do |hash,key|
    hash[key] = Hash.new do |hash,key|
        hash[key] = Hash.new
    end
end

CSV.foreach(@options[:licensecsv]) do |row|
    @licensehash[row[1]][row[0].downcase]["clustername"] = row[0].downcase
    @licensehash[row[1]][row[0].downcase]["licensetype"] = row[2]
    @licensehash[row[1]][row[0].downcase]["vcenter"] = row[1].split(/\.[A-Za-z]/).first.downcase
end

@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout]})

def getallsubs()
    subs = Array.new
    req = @api.resource(:subscriptions).call(:index, {:organization_id => @options[:org], :per_page => 50})
    subs.concat(req['results'])
    while (req['results'].length == req['per_page'].to_i)
        req = @api.resource(:subscriptions).call(:index, {:organization_id => @options[:org], :per_page => req['per_page'], :page => req['page'].to_i+1})
        subs.concat(req['results'])
    end
    return subs
end

def getfilteredsubs(searchfilter)
    subs = Array.new
    req = @api.resource(:subscriptions).call(:index, {:organization_id => @options[:org], :per_page => 50, :search => searchfilter})
    subs.concat(req['results'])
    while (req['results'].length == req['per_page'].to_i)
        req = @api.resource(:subscriptions).call(:index, {:organization_id => @options[:org], :per_page => req['per_page'], :page => req['page'].to_i+1, :search => searchfilter})
        subs.concat(req['results'])
    end
    return subs
end

def assign_license_by_name(hn,id,licname,quantity)
    begin
        mysubs = @api.resource(:host_subscriptions).call(:index,{:organization_id => @options[:org], :full_results => true, :fields => "full", :per_page => 99999, :host_id => id })
        foundsub = 0
        if mysubs["total"] > 0
            mysubs['results'].each do |mysub|
                matchname = licname.downcase
                if mysub['product_name'].downcase.eql? matchname
                    foundsub += 1
                end
            end
        end
        unless foundsub > 0
            needquant = quantity - foundsub
            #allsubs = @api.resource(:subscriptions).call(:index,{:organization_id => @options[:org], :per_page=>999999})
            allsubs = getfilteredsubs("name ~ #{licname}") 
            physicalsubs = allsubs.select {|hash| hash['virt_only'] == false}
            sub = physicalsubs.select {|hash| hash['product_name'] == licname}
            sub = sub.select{|hash| hash['available'] > 0}
            if sub.length > 0
                usesub = nil
                sub.each do |thissub|
                    if thissub['available'] >= needquant
                        usesub = thissub
                        break
                    end
                end
                unless usesub.nil?
                    if @options[:noop]
                        p "NOOP set. Would have added qty #{needquant} of #{usesub['product_name']} to #{hn} #{id}"
                    else
                        if @options[:debug]
                            p "#{hn}, #{id} , is missing enough licenses for #{licname}. Adding..."
                        end
                        addsub = @api.resource(:host_subscriptions).call(:add_subscriptions,{:organization_id => @options[:org], :host_id => id, :subscriptions=>[{:quantity=>needquant, :id=> usesub['id']}]})
                    end
                else
                    msg="Not enough #{sub[0]['product_name']} licenses available! Need #{needquant} for #{hn} #{id}"
                    error={"hostname" => hn, "id" => id, "message" => msg}
                    @errors.push(error)
                    if @options[:debug]
                        p error.to_s
                    end
                end
            else
                msg="Wrong number of remaining subs by name found for #{hn} #{id}, searching for #{licname}, found #{sub.length} subs"
                error={"hostname" => hn, "id" => id, "message" => msg}
                @errors.push(error)
                if @options[:debug]
                    p error.to_s
                end
            end
        else
            if (@options[:debug])
                p "#{hn}, #{id} , is good to go"
            end
        end
    rescue Exception => e
        crash={"hostname" => hn, "id" => id, "message" => e.message}
        @crashed.push(crash)
        if @options[:debug]
            p crash.to_s
        end
    end
end

def assign_license_by_id(hn,id,licid,quantity)
    begin
        mysubs = @api.resource(:host_subscriptions).call(:index,{:organization_id => @options[:org], :per_page => 100, :host_id => id })
        foundsub = 0
        if mysubs["total"] > 0
            mysubs['results'].each do |mysub|
                if mysub['subscription_id'].eql? licid
                    foundsub += 1
                end
            end
        end
        unless foundsub > 0
            needquant = quantity - foundsub
            #specificsub = getfilteredsubs("id ~ #{licid}")
            specificsub = @api.resource(:subscriptions).call(:show,{:organization_id => @options[:org], :per_page=>250, :id => licid})
            unless specificsub.nil? or specificsub.empty?
                if specificsub['available'] >= needquant or specificsub['available'] < 0
                    if @options[:noop]
                        p "NOOP set. Would have added qty #{needquant} of #{specificsub['product_name']} to #{hn} #{id}"
                    else
                        if @options[:debug]
                            p "#{hn}, #{id} , is missing enough licenses for #{specificsub['product_name']}. Adding..."
                        end
                        addsub = @api.resource(:host_subscriptions).call(:add_subscriptions,{:organization_id => @options[:org], :host_id => id, :subscriptions=>[{:quantity=>needquant, :id=> licid}]})
                    end
                else
                    msg="Not enough #{specificsub['product_name']} licenses available! Need #{needquant} for #{hn} #{id} but only have #{specificsub['available']} free from #{specificsub['id']}"
                    error={"hostname" => hn, "id" => id, "message" => msg}
                    @errors.push(error)
                    if @options[:debug]
                        p error.to_s
                    end
                end
            else
                msg="Wrong number of remaining subs by id found for #{hn} #{id}, searching for #{specificsub['product_name']} found #{sub.length} subs"
                error={"hostname" => hn, "id" => id, "message" => msg}
                @errors.push(error)
                if @options[:debug]
                    p error.to_s
                end
            end
        else
            if @options[:debug]
                p "#{hn}, #{id} , is good to go"
            end
        end
    rescue Exception => e
        crash={"hostname" => hn, "id" => id, "message" => e.message}
        @crashed.push(crash)
        if @options[:debug]
            p crash.to_s
        end
    end
end

def fix()
    puts "Starting fix: #{Time.new}"
    chs = []
    vghs = []
    req = @api.resource(:hosts).call(:index, {:organization_id => @options[:org], :per_page => 25})
    chs.concat(req['results'])
    while (req['results'].length == req['per_page'].to_i)
        pagenum = req['page'].to_i+1 
        req = @api.resource(:hosts).call(:index, {:organization_id => @options[:org], :per_page => req['per_page'], :page => pagenum})
        if @options[:debug]
            puts "Requested page #{pagenum} and got #{req['results'].length} results; This puts us at #{pagenum * req['results'].length} of #{req['total']}"
        end
        chs.concat(req['results'])
    end
    puts "Hosts loaded: #{Time.new}"
    chs.each do |ch|
        begin
            hn = ""
            id = ""
            hn = ch['name']
            begin
                host = @api.resource(:systems).call(:show, {:organization_id => @options[:org], :fields => "full", :id => ch["id"] })
            rescue Exception => e
                crash={"hostname" => hn, "id" => ch["id"], "message" => e.message}
                @badreg.push(crash)
                if @options[:debug]
                    p crash.to_s
                end
                next
            end
            if host['type'].downcase.match("hypervisor") || host['name'].downcase.match("virt-who")
                unless @options[:fixvmware]
                    next
                end
                hn = host['name']
                if @vmwaredata.has_key?("#{hn}")
                    vdata = @vmwaredata[hn]
                    vcenter = vdata["vcenter"].split(/\.[A-Za-z]/).first.downcase
                    cluster = vdata["cluster"].downcase
                    cpucount = vdata["cpucount"]
                    guestcount = host["virtual_guests"].length
                    @mylic = Hash.new
                    lics = @licensehash[vcenter].deep_find("#{cluster}")
                    if lics.nil?
                        if guestcount > 0
                            msg="No licenses found for cluster #{cluster} in #{vcenter}; Was checking for #{hn}. Host has #{guestcount} known Linux guests"
                            error={"hostname" => hn, "id" => id, "message" => msg}
                            @missinglicenses.push(error)
                            if @options[:debug]
                                p error.to_s
                            end
                        else
                            subs= @api.resource(:host_subscriptions).call(:index, {:host_id => host['host']['id']})
                            subs["results"].each do |sub|
                                if sub['product_name'].downcase.include? "red hat"
                                    type = sub['type']
                                    removethis = sub['id']
                                    msg={"hostname" => host['name'],"id" => host['id'],"message" => "Vhost removed sub #{sub['product_name']} with id #{removethis} of type #{type}"}
                                    @removedlicenses.push(msg)
                                    if @options[:debug]
                                        puts "Found a Vhost with a random sub! #{host['name']}, #{host['host']['id']}, has a sub for #{sub['product_name']}. It is #{type}"
                                    end
                                    if @options[:delete_unmapped_licenses]
                                        @api.resource(:host_subscriptions).call(:remove_subscriptions, {:host_id => host['host']['id'], :subscriptions => [{:id => removethis }]})
                                    end
                                end
                            end
                        end

                    else
                        msg="#{hn}, #{cluster}, #{vcenter}, #{guestcount}"
                        vhostmsg={"hostname" => hn, "id" => id, "message" => msg}
                        @vhosts.push(vhostmsg)
                        lt = lics['licensetype']
                        if lt.downcase.match("smart virtualization")
                            quantity = (cpucount / 2).ceil
                            assign_license_by_name host['name'], ch['id'], "Red Hat Enterprise Linux with Smart Virtualization, Premium (2-socket)",quantity
                            assign_license_by_name host['name'], ch['id'], "Smart Management for Unlimited Guests",1
                        elsif lt.downcase.match("physical or virtual nodes")
                            assign_license_by_name host['name'], ch['id'], "Red Hat Enterprise Linux Server, Premium (Physical or Virtual Nodes)",1
                            assign_license_by_name host['name'], ch['id'], "Smart Management",1
                        elsif lt.downcase.match("developer suite")
                            assign_license_by_name host['name'], ch['id'], "Red Hat Enterprise Linux Developer Suite",1
                        end
                    end
                else
                    if @options[:debug]
                        puts "No Vmware data found for #{hn}"
                    end
                end
            elsif host['type'].downcase.match("host")
                unless @options[:fixphysical]
                    next
                end
                cv = host['content_view']['name']
                if cv.downcase.match("oel") or cv.downcase.match("centos")
                    #eventually add smart licenses
                elsif cv.downcase.match("rhel")
                    hn = host['name'].split(/\.[A-Za-z]/).first
                    lics = @licensehash.deep_find("#{hn}")
                    if lics.nil? or lics.empty?
                        msg="No licenses found for physical host #{hn}"
                        error={"hostname" => hn, "id" => '', "message" => msg}
                        @errors.push(error)
                        if @options[:debug]
                            p error.to_s
                        end
                    else
                        lt = lics['licensetype']
                        if lt.downcase.match("physical or virtual nodes")
                            assign_license_by_name host['name'], ch['id'], "Red Hat Enterprise Linux Server, Premium (Physical or Virtual Nodes)",0
                            assign_license_by_name host['name'], ch['id'], "Smart Management",0
                        elsif lt.downcase.match("developer suite")
                            assign_license_by_name host['name'], ch['id'], "Red Hat Enterprise Linux Developer Suite",1
                        end
                    end
                else
                    if @options[:debug]
                        p "Unknown cv for physical host. Skipping #{host['name']}"
                    end
                end
            elsif host['type'].downcase.match("virtual guest")
                vghs.push(host)
            end
        rescue Exception => e
            crash={"hostname" => hn, "id" => id, "message" => e.message}
            @crashed.push(crash)
            if @options[:debug]
                p crash.to_s
            end
            next
        end
    end

    if @options[:fixguests]
        puts "Starting to license virtual guests; #{Time.now}"
        #licensing virtual guests...
        vhostsubs = @api.resource(:subscriptions).call(:index,{:organization_id => @options[:org], :full_results => true, :fields => "full", :per_page => 99999})
        puts "Vhost subs synced down"
        vghs.each do |host|
            begin
                hn = ""
                id = ""
                cv = host['content_view']['name']
                if cv.downcase.match("oel") or cv.downcase.match("centos")
                    #add smart management to virtual guests here
                elsif cv.downcase.match("rhel")
                    begin
                        subs= @api.resource(:host_subscriptions).call(:index, {:host_id => host['host']['id']})
                        subs["results"].each do |sub|
                            if sub['product_name'].downcase.include? "red hat"
                                unless sub['unmapped_guest']
                                    type = sub['type']
                                    if type != "ENTITLEMENT_DERIVED" and type != "BONUS" and type != "UNMAPPED_GUEST" and type != "STACK_DERIVED"
                                        removethis = sub['id']
                                        msg={"hostname" => host['name'],"id" => host['id'],"message" => "removed sub #{sub['product_name']} with id #{removethis} of type #{type}"}
                                        @removedlicenses.push(msg)
                                        if @options[:debug]
                                            puts "Found a random sub! #{host['name']}, #{host['host']['id']}, has a sub for #{sub['product_name']}. It is #{type}"
                                        end
                                        if @options[:delete_unmapped_licenses]
                                            @api.resource(:host_subscriptions).call(:remove_subscriptions, {:host_id => host['host']['id'], :subscriptions => [{:id => removethis }]})
                                        end
                                    end
                                end
                            end
                        end
                    rescue Exception => e
                        puts "Failed removing random subs: #{e.message}"
                    end
                    if host['virtual_host'].nil? or host['virtual_host'].empty?
                        crash={"hostname" => host['name'], "id" => host['id'], "message" => "host is virt guest, but has no virtual_host"}
                        @missingvhost.push(crash)
                        if @options[:debug]
                            p "Host #{host['name']} does not have a vhost mapping"
                        end
                        next
                    end
                    vhost = host['virtual_host']['uuid']
                    if vhost.length > 0
                        if vhostsubs.nil? or vhostsubs.empty?
                            p "No subs found for vhost #{vhost}"
                        else
                            #if dev suite, only find 1 lic; of smart virt, find two, one for rhel, one for SM
                            vhostsubs['results'].each do |vsub|
                                if vsub['virt_only']
                                    if vsub['host']['id'].eql? vhost
                                        if vsub['product_name'].downcase.match("developer")
                                            if @options[:debug]
                                                p "Assigning dev vsubs for #{host['name']}"
                                            end
                                            assign_license_by_id host['name'], host['host']['id'], vsub['id'], 1
                                        else
                                            if @options[:debug]
                                                p "Assigning prem for #{host['name']}"
                                            end
                                            assign_license_by_id host['name'], host['host']['id'], vsub['id'], 0
                                        end
                                    end 
                                end
                            end
                        end
                    end
                else
                    if @options[:debug]
                        p "Virtual host not found for #{host['name']}"
                    end
                end
            rescue Exception => e
                crash={"hostname" => host['name'], "id" => id, "message" => e.message}
                if @options[:debug]
                    p crash.to_s
                end
                @crashed.push(crash)
            end
        end
    end
end

action = ARGV.shift
stime = Time.now
if action == 'fix'
    fix
end
etime = Time.now
puts "Fixlicense took #{etime - stime}"
puts ""
if (@options[:delete_unmapped_licenses])
    puts "Removed Licenses:"
    @removedlicenses.each do |rm|
        puts "#{rm['hostname']}, #{rm['id']}, #{rm['message']}"
    end
else
    puts "Delete Unmapped Licenses was false, Otherwise I would have removed..."
    @removedlicenses.each do |rm|
        puts "#{rm['hostname']}, #{rm['id']}, #{rm['message']}"
    end
end
puts ""
puts "Missing VHost Licenses:"
@missinglicenses.each do |missing|
    puts "#{missing['hostname']}, #{missing['id']}, #{missing['message']}"
end
puts ""
puts "Vhosts:"
@vhosts.each do |vhost|
    puts "#{vhost['message']}"
end
puts "crashed hosts:"
@crashed.each do |crash|
    puts "#{crash['hostname']}, #{crash['id']}, #{crash['message']}";
end
puts ""
puts "Errored hosts:"
@errors.each do |errs|
    puts "#{errs['hostname']}, #{errs['id']}, #{errs['message']}";
end


