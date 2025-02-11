#!/usr/bin/env ruby
# main.rb
#
# This file starts the three bots (DA, Supervisor, and Client)
# concurrently in separate processes. It also initializes the database.
#
# Usage:
#   ruby main.rb

require_relative 'db'
require_relative 'da_bot'
require_relative 'supervisor_bot'
require_relative 'client_bot'

# Initialize the database (make sure Db.init_db mirrors Python’s db.init_db)
Db.init_db

pids = []

# Fork a new process for the DA Bot.
pids << fork do
  # In your da_bot.rb, define a method like `def self.run; ...; end`
  DaBot.run
end

# Fork a new process for the Supervisor Bot.
pids << fork do
  # In your supervisor_bot.rb, define a method like `def self.run; ...; end`
  SupervisorBot.run
end

# Fork a new process for the Client Bot.
pids << fork do
  # In your client_bot.rb, define a method like `def self.run; ...; end`
  ClientBot.run
end

# Wait for all child processes to exit.
pids.each { |pid| Process.wait(pid) }
