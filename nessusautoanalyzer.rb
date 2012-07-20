#!/usr/bin/env ruby

  # == Synopsis
  # This script is designed to co-ordinate parsing of nessus xml files and production of a concise set of reports which
  # are organised by severity, with an additional one for things that Nessus deems exploitable and one with vulns per host
  #
  # At the moment it only handles v2 nessus files (I may get around to adding v1 although it seems a bit pointless...)
  #
  # The scanner relies on the nokogiri gem for xml parsing
  #
  # There are 2 modes of operation.
  #
  # Directory mode just takes a parameter of the directory containing the xml files and goes and parses any files found there
  #
  # File mode takes a parameter of a single file and parses that
  #
  # == ToDo
  #
  # * Sort out HTML reports
  # * setup parsing of Nessus v1 files
  # * Add parsing for OpenVAS and NeXpose XML files
  #
  # == Author
  #   Rory McCune
  #
  # == Options
  #   -h, --help          	Displays help message
  #   -v, --version       	Display the version, then exit
  #   -d <dir>, --directory <dir>  Only needed in directory mode name of the directory to scan
  #   -f <file>, --file <file>     Only needed in file mode, name of the file to parse
  #   -r <file>, --report <file>        Name of file for reporting
  #   -l <file>             Log debug messages to a file.
  #   --reportDirectory <dir>   Place the report in a different directory
  #
  # == Usage
  #
  #   Directory Mode
  #   nmapautoanalyzer.rb -m directory -d <directoryname> -r <reportfile>
  #   File Mode
  #   nmapautoanalyzer.rb -m file -f <filename> -r <reportfile>



class NessusautoAnalyzer
  # Version of the code
  VERSION='0.0.1'
  attr_accessor :parsed_hosts, :low_vulns, :medium_vulns, :high_vulns, :info_vulns, :exploitable_vulns

  # Parse the arguments passed ans setup the options for scanning
  def initialize(arguments)
    
    #Requiring things we need.  Most of these are in stdlib, but nokogiri ain't
    begin
      require 'rubygems'
      require 'logger'
      require 'optparse'
      require 'nokogiri'
      require 'ostruct'
    rescue LoadError => e
      puts "Couldn't load one of the required gems (likely to be nokogiri)"
      puts "The error message may be useful"
      puts e.to_s
      exit
    end
    
    #Need to set this prior to running optparse as arguments.length doesn't work afterwards
    if arguments.length > 0
      arguments_flag = true
    end

    @options = OpenStruct.new
    
    #Set some defaults in the options hash
    @options.report_directory = Dir.pwd
    @options.report_file = 'nessus-parse-report'
    @options.scan_directory = Dir.pwd
    @options.scan_file = ''
    @options.scan_type = :notset
    
    
    opts = OptionParser.new do |opts|
      opts.banner = "Nessus Auto analyzer #{VERSION}"
      
      opts.on("-d", "--directory [DIRECTORY]", "Directory to scan for .nessus files") do |dir|
        @options.scan_directory = dir
        @options.scan_type = :directory
      end 
      
      opts.on("-f", "--file [FILE]", "File to analyze including path") do |file|
        @options.scan_file = file
        @options.scan_type = :file
      end
      
      opts.on("-r", "--report [REPORT]", "Base Report Name") do |rep|
        @options.report_file = rep
      end
      
      opts.on("--reportDirectory [REPORTDIRECTORY]", "Directory to output reports to") do |repdir|
        @options.report_directory = repdir
      end

      opts.on("-l", "--log [LOGGER]", "Log debugging messages to a file") do |logger|
        @options.logger = logger
      end
      
      opts.on("-h", "--help", "-?", "--?", "Get Help") do |help|
        puts opts
        exit
      end
      
      opts.on("-v", "--version", "Get Version") do |ver|
        puts "Nessus Analyzer Version #{VERSION}"
        exit
      end
      
    end
    
    opts.parse!(arguments)
    
    #Check for missing required options
    unless arguments_flag && (@options.scan_type == :file || @options.scan_type == :directory)
      puts "didn't get any arguments or missing scan type"
      puts opts
      exit
    end
    
    @base_dir = @options.report_directory
    @scan_dir = @options.scan_directory
    if !File.exists?(@base_dir)
      Dir.mkdirs(@base_dir)
    end

    if @options.logger
      @log = Logger.new(@base_dir + '/' + @options.logger)
    else
      @log = Logger.new(STDOUT)
    end
    #Change the line below to Logger::DEBUG to get debugging messages during the program run
    @log.level = Logger::ERROR
    @log.debug("Log created at " + Time.now.to_s)
    @log.debug("Scan type is : #{@options.scan_type}")
    @log.debug("Directory being scanned is : #{@options.scan_directory}") if @options.scan_type == :directory
    @log.debug("File being scanned is : #{@options.scan_file}") if @options.scan_type == :file
    
  end

  # Sets up the process for scanning the xml files and calls the individual methods depending on the scan type
  def run
    case @options.scan_type
    when :directory
      scan_dirs
      parse_files
      report
    when :file
      @scan_files = Array.new
      @scan_files << @options.scan_file
      parse_files
      report
    end
  end

  #Adds all the xml files in the directory being scanned to the scan_files array
  def scan_dirs
    @scan_files = Array.new
    Dir.entries(@scan_dir).each do |scan|

      if scan =~ /nessus$/
        @scan_files << @scan_dir + '/' + scan
      end
    end
  end

  #Set-up the Hashes to store the results of the parse commands and pass to the correct parse command depending on version
  def parse_files
    @log.debug("Files to be looked at : #{@scan_files.join(', ')}")
    #Hash for holding results on a per-host basis
    @parsed_hosts = Hash.new
    @critical_vulns = Hash.new
    @high_vulns = Hash.new
    @medium_vulns = Hash.new
    @low_vulns = Hash.new
    @info_vulns = Hash.new
    @exploitable_vulns = Hash.new
    @web_server_list = Array.new
    #Array for list of files reviewed (Do I need this?)
    @scanned_files = Array.new
    @scan_files.each do |file|      
      file_content = File.open(file,'r').read
      doc = Nokogiri::XML(file_content)
      if doc.root.name == "NessusClientData_v2"
        @log.debug("Got a v2 file called #{file}, processing")
        parse_v2_results(doc)
      elsif doc.root.name == "NessusClientData"
        @log.debug("Got a v1 file called #{file}, processing")
        parse_v1_results(doc)
      else
        @log.warn("Invalid format for file : #{file}, skipping")
        next
      end
    end

  end

  #Parse the Nessus v2 format file and populate the hashes for the report
  def parse_v2_results(doc)
    #Each host in the report has a "ReportHost" node
    hosts = doc.search('ReportHost')
    #Grabs the name of the report
    report_name = doc.search('Report')[0]['name']
    hosts.each do |host|
      ip_address = host['name']
      operating_system = host.search('tag[@name="operating-system"]').text
      fqdn = host.search('tag[@name="host-fqdn"]').text
      #Setup a hash to store the issues by host
      @parsed_hosts[ip_address] = Hash.new

      #Create a nodeset of the items in the report
      report_items = host.search('ReportItem')
      #Iterate over each item in the report
      report_items.each do |item|
        #There's some issues we're not interested in at the moment
        #Which can be identified by having no data
        next unless item.children
        #Use the pluginID as a unique key for storing vuln.
        item_id = item['pluginID']
        issue = Hash.new
        issue['risk_factor'] = item.xpath('risk_factor').text
        issue['description'] = item.xpath('description').text
        issue['port'] = item['port'] + '/' + item['protocol']
        issue['title'] = item['pluginName']
        issue['exploitable'] = item.xpath('exploitability_ease').text
        issue['plugin_output'] = item.xpath('plugin_output').text

        #Create an array and shove the cve texts in there as it makes it easy to concat them afterwards
        cve_array = Array.new
        item.xpath('cve').each {|cve| cve_array << cve.text}
        issue['cve'] = cve_array.join(', ')

		    issue['severity'] = item['severity']

        #Populate the issues by host hash
        @parsed_hosts[ip_address][item_id] = issue

        #Populate the Exploitable Set of Vulns for the test       
        if issue['exploitable'] == 'Exploits are available'
          #Below is a quick use of Ternery to check the existence of a hash and then if is exists adds the item and if it doesn't creates it and adds the item
          @exploitable_vulns[ip_address] ? @exploitable_vulns[ip_address][item_id] = issue : (@exploitable_vulns[ip_address] = Hash.new; @exploitable_vulns[ip_address][item_id] = issue)
        end
        if item['svc_name'] == 'www'
          if item.xpath('plugin_output').text =~ /TLSv1|SSLv3/
            @web_server_list << 'https://' + ip_address + ':' + item['port']
          else
            @web_server_list << 'http://' + ip_address + ':' + item['port']
          end
        end
        
        case item['severity']
        #Note items
        when '0'
          if @info_vulns[item_id] 
            @info_vulns[item_id]['affected_hosts'] << ip_address
            @info_vulns[item_id]['affected_fqdns'] << fqdn 
          else
            @info_vulns[item_id] = Hash.new
            @info_vulns[item_id]['issue'] = issue
            @info_vulns[item_id]['affected_hosts'] = Array.new
            @info_vulns[item_id]['affected_hosts'] << ip_address
            @info_vulns[item_id]['affected_fqdns'] = Array.new
            @info_vulns[item_id]['affected_fqdns'] << fqdn

          end
        #Low Items
        when '1'
          if @low_vulns[item_id] 
            @low_vulns[item_id]['affected_hosts'] << ip_address 
            @low_vulns[item_id]['affected_fqdns'] << fqdn 
          else
            @low_vulns[item_id] = Hash.new
            @low_vulns[item_id]['issue'] = issue
            @low_vulns[item_id]['affected_hosts'] = Array.new
            @low_vulns[item_id]['affected_hosts'] << ip_address
            @low_vulns[item_id]['affected_fqdns'] = Array.new
            @low_vulns[item_id]['affected_fqdns'] << fqdn

          end
        #Medium Items
        when '2'
          if @medium_vulns[item_id] 
            @medium_vulns[item_id]['affected_hosts'] << ip_address 
            @medium_vulns[item_id]['affected_fqdns'] << fqdn 
          else
            @medium_vulns[item_id] = Hash.new
            @medium_vulns[item_id]['issue'] = issue
            @medium_vulns[item_id]['affected_hosts'] = Array.new
            @medium_vulns[item_id]['affected_hosts'] << ip_address
            @medium_vulns[item_id]['affected_fqdns'] = Array.new
            @medium_vulns[item_id]['affected_fqdns'] << fqdn

          end
        #High Items
        when '3'
          if @high_vulns[item_id] 
            @high_vulns[item_id]['affected_hosts'] << ip_address 
            @high_vulns[item_id]['affected_fqdns'] << fqdn
          else
            @high_vulns[item_id] = Hash.new
            @high_vulns[item_id]['issue'] = issue
            @high_vulns[item_id]['affected_hosts'] = Array.new
            @high_vulns[item_id]['affected_hosts'] << ip_address
            @high_vulns[item_id]['affected_fqdns'] = Array.new
            @high_vulns[item_id]['affected_fqdns'] << fqdn

          end
        when '4'
          if @critical_vulns[item_id] 
            @critical_vulns[item_id]['affected_hosts'] << ip_address
            @critical_vulns[item_id]['affected_fqdns'] << fqdn
          else
            @critical_vulns[item_id] = Hash.new
            @critical_vulns[item_id]['issue'] = issue
            @critical_vulns[item_id]['affected_hosts'] = Array.new
            @critical_vulns[item_id]['affected_hosts'] << ip_address
            @critical_vulns[item_id]['affected_fqdns'] = Array.new
            @critical_vulns[item_id]['affected_fqdns'] << fqdn
          end
          
        end
      end
    end
  end

  # Not yet implemented
  def parse_v1_results(doc)
    puts "Sorry not implemented yet :) "
  end


  #Create text reports
  def report
    @exploitable_report_file = File.new(@base_dir + '/' + @options.report_file + '_nessus_exploitable.txt','w+')
    @critical_report_file = File.new(@base_dir + '/' + @options.report_file + '_nessus_critical_risk.txt','w+')
    @high_report_file = File.new(@base_dir + '/' + @options.report_file + '_nessus_high_risk.txt','w+')
    @medium_report_file = File.new(@base_dir + '/' + @options.report_file + '_nessus_medium_risk.txt','w+')
    @low_report_file = File.new(@base_dir + '/' + @options.report_file + '_nessus_low_risk.txt','w+')
    @host_report_file = File.new(@base_dir + '/' + @options.report_file + '_nessus_hosts.txt','w+')
    @web_server_report_file = File.new(@base_dir + '/' + @options.report_file + '_web_servers.txt','w+')

    @exploitable_vulns.each do |address,exploit|
      @exploitable_report_file.puts "exploitable issues for #{address}"
      @exploitable_report_file.puts "=============================\n"
      
      exploit.each do |id, issue|
        @exploitable_report_file.puts "\n--------------------"
        @exploitable_report_file.puts "exploit ID : #{id}"
        @exploitable_report_file.puts "Issue Name : #{issue['title']}"
        @exploitable_report_file.puts "Issue Port : #{issue['port']}"
      end
    end
    @log.debug("high Vulns : " + @high_vulns.length.to_s)
    @log.debug("medium Vulns : " + @medium_vulns.length.to_s)
    @log.debug("Low Vulns : " + @low_vulns.length.to_s)
    @log.debug("Info Vulns : " + @info_vulns.length.to_s)
    @high_report_file.puts "High Risk Issues"
    @high_report_file.puts "=================\n"
    @high_vulns.each do |item, results|
      @high_report_file.puts results['issue']['title']
      @high_report_file.puts "CVE : " + results['issue']['cve']
      @high_report_file.puts "Exploitability : " + results['issue']['exploitable']
      @high_report_file.puts "Affected Hosts : " + results['affected_hosts'].uniq.join(', ')
      @high_report_file.puts "Affected Hosts : " + results['affected_fqdns'].uniq.join(', ')
      @high_report_file.puts "\n------------------\n"
    end
    @critical_report_file.puts "Critical Risk Issues"
    @critical_report_file.puts "=================\n"
    @critical_vulns.each do |item, results|
      @critical_report_file.puts results['issue']['title']
      @critical_report_file.puts "CVE : " + results['issue']['cve']
      @critical_report_file.puts "Exploitability : " + results['issue']['exploitable']
      @critical_report_file.puts "Affected Hosts : " + results['affected_hosts'].uniq.join(', ')
      @critical_report_file.puts "Affected Hosts : " + results['affected_fqdns'].uniq.join(', ')
      @critical_report_file.puts "\n------------------\n"
    end
    @medium_report_file.puts "Medium Risk Issues"
    @medium_report_file.puts "=================\n"
    @medium_vulns.each do |item, results|
      @medium_report_file.puts results['issue']['title']
      @medium_report_file.puts "CVE : " + results['issue']['cve']
      @medium_report_file.puts "Exploitability : " + results['issue']['exploitable']
      @medium_report_file.puts "Affected Hosts : " + results['affected_hosts'].uniq.join(', ')
      @medium_report_file.puts "Affected Hosts : " + results['affected_fqdns'].uniq.join(', ')
      @medium_report_file.puts "\n------------------\n"
    end
    @low_report_file.puts "Low Risk Issues"
    @low_report_file.puts "=================\n"
    @low_vulns.each do |item, results|
      @low_report_file.puts results['issue']['title']
      @low_report_file.puts "CVE : " + results['issue']['cve']
      @low_report_file.puts "Exploitability : " + results['issue']['exploitable']
      @low_report_file.puts "Affected Hosts : " + results['affected_hosts'].uniq.join(', ')
      @low_report_file.puts "Affected Hosts : " + results['affected_fqdns'].uniq.join(', ')
      @low_report_file.puts "\n------------------\n"
    end
    
    @web_server_list.uniq.each do |host|
      @web_server_report_file.puts host
    end

    @host_report_file.puts "Issues by Host"
    @host_report_file.puts "===============\n"
    @parsed_hosts.each do |ip_address, results|
      @host_report_file.puts "Results for #{ip_address}"
      @host_report_file.puts "=======================\n"
      results.each do |item,issue|
        @host_report_file.puts issue['title']
	@host_report_file.puts "CVE : " + issue['cve'] if issue['cve'].length > 0
	@host_report_file.puts "Severity : " + issue['severity']
	@host_report_file.puts "Description : " + issue['description']
        @host_report_file.puts ""
        @host_report_file.puts "Plugin Output: " + issue['plugin_output'] if issue['plugin_output'].length > 0
        @host_report_file.puts "\n-------------------\n"
      end
    end	
  end
end

if __FILE__ == $0
  analysis = NessusautoAnalyzer.new(ARGV)
  analysis.run
end
