require 'telegram/bot'
require_relative 'config'
require_relative 'db'

module Notifier
  DA_BOT         = Telegram::Bot::Client.new(Config::DA_BOT_TOKEN)
  SUPERVISOR_BOT = Telegram::Bot::Client.new(Config::SUPERVISOR_BOT_TOKEN)
  CLIENT_BOT     = Telegram::Bot::Client.new(Config::CLIENT_BOT_TOKEN)

  def self.notify_supervisors(ticket)
    supervisors = DB.get_users_by_role("supervisor")
    supervisors.each do |sup|
      message = "تم إنشاء بلاغ جديد.\n" +
                "رقم التذكرة: #{ticket['ticket_id']}\n" +
                "رقم الأوردر: #{ticket['order_id']}\n" +
                "الوصف: #{ticket['issue_description']}"
      markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض التفاصيل", callback_data: "view|#{ticket['ticket_id']}")]
      ])
      begin
        if ticket['image_url'] && !ticket['image_url'].empty?
          SUPERVISOR_BOT.api.send_photo(chat_id: sup["chat_id"],
                                         photo: ticket['image_url'],
                                         caption: message,
                                         reply_markup: markup,
                                         parse_mode: "HTML")
        else
          SUPERVISOR_BOT.api.send_message(chat_id: sup["chat_id"],
                                          text: message,
                                          reply_markup: markup,
                                          parse_mode: "HTML")
        end
      rescue => e
        puts "Error notifying supervisor #{sup['chat_id']}: #{e}"
      end
    end
  end

  def self.notify_client(ticket)
    clients = DB.get_users_by_role("client", ticket["client"])
    clients.each do |client|
      message = "تم رفع بلاغ يتعلق بطلب #{ticket['order_id']}.\n" +
                "الوصف: #{ticket['issue_description']}\n" +
                "النوع: #{ticket['issue_type']}"
      markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض التفاصيل", callback_data: "client_view|#{ticket['ticket_id']}")]
      ])
      begin
        if ticket['image_url'] && !ticket['image_url'].empty?
          CLIENT_BOT.api.send_photo(chat_id: client["chat_id"],
                                    photo: ticket['image_url'],
                                    caption: message,
                                    reply_markup: markup,
                                    parse_mode: "HTML")
        else
          CLIENT_BOT.api.send_message(chat_id: client["chat_id"],
                                      text: message,
                                      reply_markup: markup,
                                      parse_mode: "HTML")
        end
      rescue => e
        puts "Error notifying client: #{e}"
      end
    end
  end

  def self.notify_da(ticket)
    da_user = DB.get_user(ticket["da_id"], "da")
    if da_user
      message = "تم تحديث بلاغك رقم #{ticket['ticket_id']}.\n" +
                "الوصف: #{ticket['issue_description']}\n" +
                "الحالة: #{ticket['status']}"
      markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض التفاصيل", callback_data: "da_view|#{ticket['ticket_id']}")]
      ])
      begin
        if ticket['image_url'] && !ticket['image_url'].empty?
          DA_BOT.api.send_photo(chat_id: da_user["chat_id"],
                                photo: ticket['image_url'],
                                caption: message,
                                reply_markup: markup,
                                parse_mode: "HTML")
        else
          DA_BOT.api.send_message(chat_id: da_user["chat_id"],
                                  text: message,
                                  reply_markup: markup,
                                  parse_mode: "HTML")
        end
      rescue => e
        puts "Error notifying DA: #{e}"
      end
    end
  end
end
