#!/usr/bin/env ruby

# == Author
# Author::  Rory McCune
# Copyright:: Copyright (c) 2013 Rory Mccune
# License:: GPLv3
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class WebScreenRecon

  VERSION = '0.0.1'



  def initialize(arguments)

    require 'logger'
    require 'optparse'
    require 'ostruct'

    begin
      require 'headless'
      require 'selenium-webdriver'
    rescue LoadError
      puts "Couldn't install required gems"
      puts "Try bundle install or gem install headless selenium-webdriver"
      exit
    end

    begin
      require 'nokogiri'
    rescue LoadError
      puts "Couldn't load nokogir"
      puts "try gem install nokogiri"
      exit
    end

    base_dir = File.expand_path( File.dirname(__FILE__))

    @options = OpenStruct.new
    @options.input_file = ''
    @options.output_dir = base_dir
    @options.log_file = 'WSRT.log'
    @options.sleep_time = 5


    opts = OptionParser.new do |opts|
      opts.banner = "Web Screen Cap Reconnaissance tool #{VERSION}"

      opts.on("-f", "--file [FILE]", "Input File with IP/Host List") do |file|
        @options.input_file = file
      end

      opts.on("-d", "--directory [DIRECTORY]", "Output Directory for Screen Caps") do |dir|
        @options.output_dir = File.expand_path(dir)
      end

      opts.on("-s", "--sleep [SECONDS]", "Number of seconds to sleep before screenshot") do |sleep|
        @options.sleep_time = sleep
      end

      opts.on("-h", "--help", "-?", "--?", "Get Help") do |help|
        puts opts
        exit
      end

      opts.on("-v", "--version", "Get Version") do |ver|
        puts "Web Screen Cap Reconnaissance Tool #{VERSION}"
        exit
      end
    end

    opts.parse!(arguments)

    unless @options.input_file.length > 0
      puts "Need to specify an input file!"
      puts opts
      exit
    end

    begin
      @input_file = File.open(@options.input_file,'r')
    rescue Exception => e
      puts "Couldn't open the input file provided, check permissions/spelling?"
      puts e
      exit
    end

    unless File.exists?(@options.output_dir)
      begin
        Dir.mkdir(@options.output_dir)
      rescue Exception => e
        puts "Whoops, couldn't create output directory "
        puts e
        exit
      end
    end
    @log = Logger.new(File.expand_path(@options.output_dir) + '/WSRT.log')
    @log.level = Logger::DEBUG
    @log.info("Log created at " + Time.now.to_s)
    @log.debug("Input File is #{@options.input_file}")
    @log.debug("Output Directory is #{@options.output_dir}")
    @output_file_names = Hash.new
    parse_input_file
  end

  def cap
    @headless = Headless.new
    @headless.start
    Selenium::WebDriver::Firefox.path = '/usr/lib/firefox/firefox'
    Selenium::WebDriver::Chrome.path = '/opt/google/chrome/google-chrome'
    @driver = Selenium::WebDriver.for :firefox
    Dir.chdir(@options.output_dir)
    @target_addresses.each do |ip|
      begin
        filename = ip.gsub(/[\,\:\/]/,'_') + ".png"
        puts filename
        @driver = Selenium::WebDriver.for :firefox
        @driver.navigate.to ip
        sleep(@options.sleep_time)
        @headless.take_screenshot(filename)
        @output_file_names[ip] = filename
        @log.info("Saved " + ip)
        @driver.quit
      rescue Timeout::Error
        @log.warn "Whoops didn't work with address " + ip
        #If we timeout close the driver and open a new one
        @driver.quit
        @driver = Selenium::WebDriver.for :firefox
      rescue Selenium::WebDriver::Error::WebDriverError
        @log.warn "darn unstable firefox"
        @driver.quit
        @driver = Selenium::WebDriver.for :firefox
      end

    end
  end

  def generate_html_report
    Dir.chdir(@options.output_dir)
    @builder = Nokogiri::HTML::Builder.new do |doc|
      doc.html {
        doc.head {
          doc.title "rWSRT Report"
          doc.style {
            doc.text "table, th, td {border: 1px solid black;}"
            doc.text "td {text-align:center;}"
            doc.text "td {padding:25px;}"
            doc.text "a:link {font-size: 24px;}"
          }
        }
        doc.body {
          doc.h1 "rWSRT Report"
          doc.table {
            @output_file_names.each do |host, filename|
              doc.tr {
                doc.td {
                  doc.a host, :href => host
                  doc.br
                  doc.img(:src => filename)
                }
              }
            end
          }
        }
      }
    end
    @report_file = File.new('rWSRT.html','w+')
    @report_file.puts @builder.to_html
  end

  private
  def parse_input_file
    @target_addresses = Array.new
    @input_array = @input_file.readlines
    @input_array.each {|line| line.chomp!}
    @input_array.each do |line|
      if line =~ /\,/
        addresses = line.split(',')
        @target_addresses = @target_addresses + addresses
      else
        @target_addresses << line
      end
    end

    @target_addresses.collect! do |address|
      unless address =~ /^http/
        if address.split(':')[1] == '443'
          address = 'https://' + address + '/'
        else
          address = 'http://' + address + '/'
        end
      end
      puts address
      address
    end
  end


end


if __FILE__ == $0
  capture = WebScreenRecon.new(ARGV)
  capture.cap
  capture.generate_html_report
end
