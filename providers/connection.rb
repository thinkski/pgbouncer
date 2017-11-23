#
# Cookbook Name:: pgbouncer
# Provider:: connection
#
# Copyright 2010-2013, Whitepages Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# check to see if we are in systemd
# taken from https://stackoverflow.com/questions/16309808/how-can-i-put-the-output-of-a-chef-execute-resource-into-a-variable


init_systemd = `bash -c '[[ \`systemctl\` =~ -\.mount ]] && echo 1 || echo 0'`.strip
init_upstart = `bash -c '[[ \`/sbin/init --version\` =~ upstart ]] && echo 1 || echo 0'`.strip

init_system = 'sysv'
if init_systemd == '1'
  init_system = 'systemd'
elsif init_upstart == '1'
  init_system = 'upstart'
end


def initialize(*args)
  super
  @action = :setup
end

action :start do
  service "pgbouncer-#{new_resource.db_alias}-start" do
    service_name "pgbouncer-#{new_resource.db_alias}" # this is to eliminate warnings around http://tickets.opscode.com/browse/CHEF-3694
    action [:enable, :start]
    provider Chef::Provider::Service::Upstart
  end
end

action :restart do
  service "pgbouncer-#{new_resource.db_alias}-restart" do
    service_name "pgbouncer-#{new_resource.db_alias}" # this is to eliminate warnings around http://tickets.opscode.com/browse/CHEF-3694
    action [:enable, :restart]
    provider Chef::Provider::Service::Upstart
  end
end

action :stop do
  service "pgbouncer-#{new_resource.db_alias}-stop" do
    service_name "pgbouncer-#{new_resource.db_alias}" # this is to eliminate warnings around http://tickets.opscode.com/browse/CHEF-3694
    action :stop
    provider Chef::Provider::Service::Upstart
  end
end

action :setup do

  group new_resource.group do
  end

  user new_resource.user do
    gid new_resource.group
    system true
  end

  # install the pgbouncer package
  #
  package 'pgbouncer' do
    action [:install]
  end

  # create the log, pid, db_sockets, /etc/pgbouncer, and application socket directories
  [
   new_resource.log_dir,
   new_resource.pid_dir,
   new_resource.socket_dir,
   ::File.expand_path(::File.join(new_resource.socket_dir, new_resource.db_alias)),
   '/etc/pgbouncer'
  ].each do |dir|
    directory dir do
      action :create
      recursive true
      owner new_resource.user
      group new_resource.group
      mode 0775
    end
  end

  template_variables = {
    db_alias: new_resource.db_alias,
    db_host: new_resource.db_host,
    db_port: new_resource.db_port,
    db_name: new_resource.db_name,

    userlist: new_resource.userlist,

    db_ref: new_resource.db_ref,

    listen_addr: new_resource.listen_addr,
    listen_port: new_resource.listen_port,

    user: new_resource.user,
    group: new_resource.group,
    log_dir: new_resource.log_dir,
    socket_dir: new_resource.socket_dir,
    pid_dir: new_resource.pid_dir,

    pool_mode: new_resource.pool_mode,
    max_client_conn: new_resource.max_client_conn,
    default_pool_size: new_resource.default_pool_size,
    min_pool_size: new_resource.min_pool_size,
    reserve_pool_size: new_resource.reserve_pool_size,
    server_idle_timeout: new_resource.server_idle_timeout,

    server_reset_query: new_resource.server_reset_query,
    connect_query: new_resource.connect_query,
  }
  unless new_resource.tcp_keepalive.nil?
    template_variables[:tcp_keepalive] = new_resource.tcp_keepalive
  end
  unless new_resource.tcp_keepidle.nil?
    template_variables[:tcp_keepidle] = new_resource.tcp_keepidle
  end
  unless new_resource.tcp_keepintvl.nil?
    template_variables[:tcp_keepintvl] = new_resource.tcp_keepintvl
  end

  # create a ruby block resource that will collect all intermediate 
  # notifications for settings changes and then restart the service if needed
  # at the end of the script
  ruby_block "service_pgbouncer_restart_notifier" do
    block do
      node.run_state[:pgbouncer_srv_restart] = true
    end
    action :create
  end

  # build the userlist, pgbouncer.ini and logrotate.d templates
  {
    "/etc/pgbouncer/userlist-#{new_resource.db_alias}.txt" => 'etc/pgbouncer/userlist2.txt.erb',
    "/etc/pgbouncer/pgbouncer-#{new_resource.db_alias}.ini" => 'etc/pgbouncer/pgbouncer2.ini.erb', 
    "/etc/logrotate.d/pgbouncer-#{new_resource.db_alias}" => 'etc/logrotate.d/pgbouncer-logrotate.d.erb', 
  }.each do |key, source_template|
    ## We are setting destination_file to a duplicate of key because the hash
    ## key is frozen and immutable.
    destination_file = key.dup

    template destination_file do
      cookbook 'pgbouncer'
      source source_template
      owner new_resource.user
      group new_resource.group
      mode '0644'
      notifies :run, "ruby_block[service_pgbouncer_restart_notifier]", :immediate
      variables(template_variables)
    end
  end

#      notifies :restart, "service[pgbouncer-#{new_resource.db_alias}]"


  if init_system == 'upstart'
    data = {
      :dest => "/etc/init/pgbouncer-#{new_resource.db_alias}.conf",
      :src => 'etc/init/pgbouncer.conf.erb', 
      :mode => '0644', 
      :owner => new_resource.user, 
      :group => new_resource.group,
      :provider => Chef::Provider::Service::Upstart}
  elsif init_system == 'systemd'
    data = {
      :dest => "/etc/systemd/system/pgbouncer-#{new_resource.db_alias}.service",
      :src => 'etc/systemd/system/pgbouncer.service.erb', 
      :mode => '0755', 
      :owner => 'root', 
      :group => 'root',
      :provider => Chef::Provider::Service::Systemd}
  else
    data = {
      :dest => "/etc/init.d/pgbouncer-#{new_resource.db_alias}",
      :src => 'etc/init.d/pgbouncer.erb', 
      :mode => '0644', 
      :owner => 'root', 
      :group => 'root',
      :provider => Chef::Provider::Service::Init}
  end

  # create the service runner
  template data[:dest] do
    cookbook 'pgbouncer'
    source data[:src]
    owner data[:owner]
    group data[:group]
    mode data[:mode]
    notifies :run, "ruby_block[service_pgbouncer_restart_notifier]", :immediate
    variables(template_variables)
  end

  service "pgbouncer-#{new_resource.db_alias}" do
    supports :enable => true, :start => true, :restart => true
    provider data[:provider]
    action :nothing
  end

  service "pgbouncer-#{new_resource.db_alias}" do
    action :restart
    only_if { node.run_state[:pgbouncer_srv_restart] }
  end

  new_resource.updated_by_last_action(true)
end

action :teardown do

  remove_files = [
    "/etc/pgbouncer/userlist-#{new_resource.db_alias}.txt",
    "/etc/pgbouncer/pgbouncer-#{new_resource.db_alias}.ini",
    "/etc/logrotate.d/pgbouncer-#{new_resource.db_alias}",
    "/etc/init/pgbouncer-#{new_resource.db_alias}.conf",
    "/etc/systemd/system/pgbouncer-#{new_resource.db_alias}.service",
    "/etc/init.d/pgbouncer-#{new_resource.db_alias}",
  ]

  remove_files.each do |destination_file, source_template|
    file destination_file do
      action :delete
    end
  end

  new_resource.updated_by_last_action(true)
end

