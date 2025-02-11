#!/usr/bin/env ruby
require 'sinatra'
require 'json'
require_relative 'db'

set :port, 5000
set :bind, '0.0.0.0'

COMMON_STYLE = <<~CSS
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Open+Sans:wght@300;400;600&display=swap');
    * {
        font-family: 'Open Sans', sans-serif;
        box-sizing: border-box;
        margin: 0;
        padding: 0;
    }
    body {
        background: #f0f2f5;
        padding: 2rem;
        max-width: 1200px;
        margin: 0 auto;
    }
    h1 {
        color: #1a73e8;
        margin-bottom: 2rem;
        text-align: center;
        font-weight: 600;
        animation: fadeIn 0.8s ease-in;
    }
    table {
        width: 100%;
        border-collapse: collapse;
        margin: 1.5rem 0;
        box-shadow: 0 1px 3px rgba(0,0,0,0.12);
        background: white;
        border-radius: 8px;
        overflow: hidden;
        animation: slideUp 0.6s ease-out;
    }
    th, td {
        padding: 15px;
        text-align: left;
        border-bottom: 1px solid #e0e0e0;
    }
    th {
        background-color: #1a73e8;
        color: white;
        font-weight: 600;
    }
    tr:hover {
        background-color: #f8f9fa;
        transition: background 0.3s ease;
    }
    tr:nth-child(even) {
        background-color: #f8f9fa;
    }
    a {
        color: #1a73e8;
        text-decoration: none;
        transition: color 0.3s ease;
    }
    a:hover {
        color: #1557b0;
        text-decoration: underline;
    }
    .button {
        display: inline-block;
        padding: 8px 16px;
        background: #1a73e8;
        color: white !important;
        border-radius: 4px;
        margin: 0.5rem 0;
        transition: transform 0.2s ease;
    }
    .button:hover {
        transform: translateY(-2px);
        text-decoration: none;
    }
    pre {
        background: #f8f9fa;
        padding: 1rem;
        border-radius: 8px;
        white-space: pre-wrap;
        word-wrap: break-word;
        border: 1px solid #e0e0e0;
        animation: fadeIn 0.8s ease-in;
    }
    @keyframes fadeIn {
        from { opacity: 0; }
        to { opacity: 1; }
    }
    @keyframes slideUp {
        from { transform: translateY(20px); opacity: 0; }
        to { transform: translateY(0); opacity: 1; }
    }
    .status-indicator {
        display: inline-block;
        width: 12px;
        height: 12px;
        border-radius: 50%;
        margin-right: 8px;
    }
    .status-open { background-color: #34a853; }
    .status-pending { background-color: #fbbc05; }
    .status-closed { background-color: #ea4335; }
    .log-entry {
        margin: 0.5rem 0;
        padding: 0.5rem;
        border-left: 3px solid #1a73e8;
        background: #f8f9fa;
        animation: slideIn 0.4s ease-out;
    }
    @keyframes slideIn {
        from { transform: translateX(-20px); opacity: 0; }
        to { transform: translateX(0); opacity: 1; }
    }
  </style>
CSS

HOME_TEMPLATE = <<~HTML
  <!doctype html>
  <html>
  <head>
    <title>Issue Resolution Admin</title>
    #{COMMON_STYLE}
  </head>
  <body>
    <h1>Issue Resolution Admin</h1>
    <div class="card-container">
      <div class="card">
        <h2>Tickets Management</h2>
        <a class="button" href="/tickets">View All Tickets</a>
      </div>
      <div class="card">
        <h2>Subscriptions</h2>
        <a class="button" href="/subscriptions">View Subscriptions</a>
      </div>
    </div>
    <style>
      .card-container {
          display: flex;
          gap: 2rem;
          justify-content: center;
          margin-top: 2rem;
      }
      .card {
          background: white;
          padding: 2rem;
          border-radius: 12px;
          box-shadow: 0 2px 8px rgba(0,0,0,0.1);
          text-align: center;
          transition: transform 0.3s ease;
      }
      .card:hover {
          transform: translateY(-5px);
      }
      .card h2 {
          color: #1a73e8;
          margin-bottom: 1rem;
          font-size: 1.4rem;
      }
    </style>
  </body>
  </html>
HTML

TICKETS_TEMPLATE = <<~HTML
  <!doctype html>
  <html>
  <head>
    <title>Tickets</title>
    #{COMMON_STYLE}
  </head>
  <body>
    <h1>Tickets</h1>
    <table>
      <tr>
        <th>ID</th>
        <th>Order ID</th>
        <th>Issue Description</th>
        <th>سبب المشكلة</th>
        <th>نوع المشكلة</th>
        <th>Client</th>
        <th>الصورة</th>
        <th>Status</th>
        <th>DA ID</th>
        <th>Created At</th>
        <th>النشاط</th>
      </tr>
      <% tickets.each do |t| %>
      <tr>
        <td><%= t['ticket_id'] %></td>
        <td><%= t['order_id'] %></td>
        <td><%= t['issue_description'] %></td>
        <td><%= t['issue_reason'] %></td>
        <td><%= t['issue_type'] %></td>
        <td><%= t['client'] %></td>
        <td>
          <% if t['image_url'] && !t['image_url'].empty? %>
            <img src="<%= t['image_url'] %>" width="100">
          <% else %>
            لا توجد
          <% end %>
        </td>
        <td>
          <span class="status-indicator status-<%= t['status'].downcase %>"></span>
          <%= t['status'] %>
        </td>
        <td><%= t['da_id'] %></td>
        <td><%= t['created_at'] %></td>
        <td><a class="button" href="/ticket/<%= t['ticket_id'] %>/activity">عرض النشاط</a></td>
      </tr>
      <% end %>
    </table>
    <a class="button" href="/">Back to Home</a>
  </body>
  </html>
HTML

SUBSCRIPTIONS_TEMPLATE = <<~HTML
  <!doctype html>
  <html>
  <head>
    <title>Subscriptions</title>
    #{COMMON_STYLE}
  </head>
  <body>
    <h1>Subscriptions</h1>
    <table>
      <tr>
        <th>User ID</th>
        <th>Role</th>
        <th>Bot</th>
        <th>Phone</th>
        <th>Client</th>
        <th>Username</th>
        <th>First Name</th>
        <th>Last Name</th>
        <th>Chat ID</th>
      </tr>
      <% subs.each do |u| %>
      <tr>
        <td><%= u['user_id'] %></td>
        <td><%= u['role'] %></td>
        <td><%= u['bot'] %></td>
        <td><%= u['phone'] %></td>
        <td><%= u['client'] %></td>
        <td>@<%= u['username'] %></td>
        <td><%= u['first_name'] %></td>
        <td><%= u['last_name'] %></td>
        <td><%= u['chat_id'] %></td>
      </tr>
      <% end %>
    </table>
    <a class="button" href="/">Back to Home</a>
  </body>
  </html>
HTML

ACTIVITY_TEMPLATE = <<~HTML
  <!doctype html>
  <html>
  <head>
    <title>Ticket Activity</title>
    #{COMMON_STYLE}
  </head>
  <body>
    <h1>Activity for Ticket #<%= ticket_id %></h1>
    <div class="activity-container">
      <% if image_url && !image_url.empty? %>
      <div>
        <img src="<%= image_url %>" width="200">
      </div>
      <% end %>
      <% logs.split("\n").each do |entry| %>
      <div class="log-entry"><%= entry %></div>
      <% end %>
    </div>
    <a class="button" href="/tickets">Back to Tickets</a>
  </body>
  </html>
HTML

get '/' do
  HOME_TEMPLATE
end

get '/tickets' do
  tickets = DB.get_all_tickets
  erb TICKETS_TEMPLATE, locals: { tickets: tickets }
end

get '/ticket/:ticket_id/activity' do
  ticket_id = params[:ticket_id].to_i
  ticket = DB.get_ticket(ticket_id)
  halt 404, "Ticket not found" if ticket.nil?
  logs = begin
    logs_list = JSON.parse(ticket['logs'] || '[]')
    JSON.pretty_generate(logs_list)
  rescue
    "لا توجد سجلات إضافية."
  end
  erb ACTIVITY_TEMPLATE, locals: { ticket_id: ticket_id, logs: logs, image_url: ticket['image_url'] }
end

get '/subscriptions' do
  subs = DB.get_all_subscriptions
  erb SUBSCRIPTIONS_TEMPLATE, locals: { subs: subs }
end
