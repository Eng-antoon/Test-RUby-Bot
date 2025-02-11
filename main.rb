#!/usr/bin/env ruby
require_relative 'db'
require_relative 'da_bot'
require_relative 'supervisor_bot'
require_relative 'client_bot'

# Initialize the database
DB.init_db

pids = []

# Fork a new process for the DA Bot.
pids << fork do
  DaBot.run
end

# Fork a new process for the Supervisor Bot.
pids << fork do
  SupervisorBot.run
end

# Fork a new process for the Client Bot.
pids << fork do
  ClientBot.run
end

# Wait for all child processes to exit.
pids.each { |pid| Process.wait(pid) }
