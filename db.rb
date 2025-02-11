require 'sqlite3'
require 'json'
require 'time'
require_relative '../config/config'

module DB
  def self.get_connection
    db = SQLite3::Database.new(Config::DATABASE, results_as_hash: true)
    db.execute("PRAGMA busy_timeout = 10000")
    db
  end

  def self.init_db
    db = get_connection
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS subscriptions (
        user_id INTEGER,
        role TEXT,
        bot TEXT,
        phone TEXT,
        client TEXT,
        username TEXT,
        first_name TEXT,
        last_name TEXT,
        chat_id INTEGER,
        PRIMARY KEY (user_id, bot)
      );
    SQL
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS tickets (
        ticket_id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id TEXT,
        issue_description TEXT,
        issue_reason TEXT,
        issue_type TEXT,
        client TEXT,
        image_url TEXT,
        status TEXT,
        da_id INTEGER,
        logs TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    SQL
    db.close
  end

  def self.add_subscription(user_id, phone, role, bot, client, username, first_name, last_name, chat_id)
    db = get_connection
    db.execute("INSERT OR REPLACE INTO subscriptions 
                (user_id, role, bot, phone, client, username, first_name, last_name, chat_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                user_id, role, bot, phone, client, username, first_name, last_name, chat_id)
    db.close
  end

  def self.get_subscription(user_id, bot)
    db = get_connection
    result = db.get_first_row("SELECT * FROM subscriptions WHERE user_id = ? AND bot = ?", user_id, bot)
    db.close
    result
  end

  def self.get_all_subscriptions
    db = get_connection
    result = db.execute("SELECT * FROM subscriptions")
    db.close
    result
  end

  def self.add_ticket(order_id, issue_description, issue_reason, issue_type, client, image_url, status, da_id)
    log_entry = [{ "action" => "ticket_created", "by" => da_id, "timestamp" => Time.now.iso8601 }].to_json
    db = get_connection
    db.execute("INSERT INTO tickets 
                (order_id, issue_description, issue_reason, issue_type, client, image_url, status, da_id, logs)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                order_id, issue_description, issue_reason, issue_type, client, image_url, status, da_id, log_entry)
    ticket_id = db.last_insert_row_id
    db.close
    ticket_id
  end

  def self.get_ticket(ticket_id)
    db = get_connection
    result = db.get_first_row("SELECT * FROM tickets WHERE ticket_id = ?", ticket_id)
    db.close
    result
  end

  def self.get_all_tickets
    db = get_connection
    result = db.execute("SELECT * FROM tickets")
    db.close
    result
  end

  def self.update_ticket_status(ticket_id, new_status, log_entry)
    log_entry["timestamp"] = Time.now.iso8601
    db = get_connection
    current_logs = db.get_first_value("SELECT logs FROM tickets WHERE ticket_id = ?", ticket_id)
    logs = current_logs && !current_logs.empty? ? JSON.parse(current_logs) : []
    logs << log_entry
    logs_str = logs.to_json
    db.execute("UPDATE tickets SET status = ?, logs = ? WHERE ticket_id = ?", new_status, logs_str, ticket_id)
    db.close
  end

  def self.search_tickets_by_order(order_id)
    db = get_connection
    result = db.execute("SELECT * FROM tickets WHERE order_id LIKE ?", "%#{order_id}%")
    db.close
    result
  end

  def self.get_all_open_tickets
    statuses = ['Opened', 'Pending DA Action', 'Awaiting Client Response', 'Awaiting Supervisor Approval', 'Client Responded', 'Client Ignored']
    placeholders = statuses.map { "?" }.join(",")
    db = get_connection
    result = db.execute("SELECT * FROM tickets WHERE status IN (#{placeholders})", statuses)
    db.close
    result
  end

  def self.get_supervisors
    db = get_connection
    result = db.execute("SELECT * FROM subscriptions WHERE role = 'Supervisor'")
    db.close
    result
  end

  def self.get_clients_by_name(client_name)
    db = get_connection
    result = db.execute("SELECT * FROM subscriptions WHERE role = 'Client' AND client = ?", client_name)
    db.close
    result
  end

  def self.get_users_by_role(role, client = nil)
    db = get_connection
    if client
      result = db.execute("SELECT * FROM subscriptions WHERE role = ? AND client = ?", role.capitalize, client)
    else
      result = db.execute("SELECT * FROM subscriptions WHERE role = ?", role.capitalize)
    end
    db.close
    result
  end

  def self.get_user(user_id, bot)
    get_subscription(user_id, bot)
  end
end

# If run directly, initialize the database:
if __FILE__ == $0
  init_db
  puts "Database initialized."
end
