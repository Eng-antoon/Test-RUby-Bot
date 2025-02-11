# client_bot.rb
require 'telegram/bot'
require_relative 'config'
require_relative 'db'
require_relative 'notifier'

module ClientBot
  # Conversation states
  SUBSCRIPTION_PHONE = 0
  SUBSCRIPTION_CLIENT  = 1
  MAIN_MENU            = 2
  AWAITING_RESPONSE    = 3

  $client_states = {}

  def self.safe_edit_message(bot, message, text, reply_markup = nil)
    if message.respond_to?(:caption) && message.caption
      bot.api.editMessageCaption(
        chat_id: message.chat.id,
        message_id: message.message_id,
        caption: text,
        reply_markup: reply_markup,
        parse_mode: "HTML"
      )
    else
      bot.api.editMessageText(
        chat_id: message.chat.id,
        message_id: message.message_id,
        text: text,
        reply_markup: reply_markup,
        parse_mode: "HTML"
      )
    end
  end

  def self.start(bot, message)
    user = message.from
    sub = DB.get_subscription(user.id, "Client")
    chat_id = message.chat.id
    $client_states[chat_id] ||= {}  # ensure state hash
    if sub.nil?
      bot.api.send_message(chat_id: chat_id, text: "أهلاً! يرجى إدخال رقم هاتفك للاشتراك (Client):")
      $client_states[chat_id][:state] = SUBSCRIPTION_PHONE
    elsif sub["client"].nil? || sub["client"].empty?
      bot.api.send_message(chat_id: chat_id, text: "يرجى إدخال اسم العميل الذي تمثله (مثال: بيبس):")
      $client_states[chat_id][:state] = SUBSCRIPTION_CLIENT
    else
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض المشاكل", callback_data: "menu_show_tickets")]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "مرحباً #{user.first_name}", reply_markup: keyboard)
      $client_states[chat_id][:state] = MAIN_MENU
    end
  end

  def self.handle_message(bot, message)
    chat_id = message.chat.id
    $client_states[chat_id] ||= {}
    state_info = $client_states[chat_id]
    case state_info[:state]
    when SUBSCRIPTION_PHONE
      phone = message.text.strip
      user = message.from
      DB.add_subscription(user.id, phone, "Client", "Client", nil,
                          user.username, user.first_name, user.last_name, chat_id)
      bot.api.send_message(chat_id: chat_id, text: "تم استقبال رقم الهاتف. الآن، يرجى إدخال اسم العميل الذي تمثله (مثال: بيبس):")
      $client_states[chat_id][:state] = SUBSCRIPTION_CLIENT
    when SUBSCRIPTION_CLIENT
      client_name = message.text.strip
      user = message.from
      sub = DB.get_subscription(user.id, "Client")
      phone = (sub && sub["phone"] && sub["phone"] != "unknown") ? sub["phone"] : "unknown"
      DB.add_subscription(user.id, phone, "Client", "Client", client_name,
                          user.username, user.first_name, user.last_name, chat_id)
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض المشاكل", callback_data: "menu_show_tickets")]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "تم الاشتراك بنجاح كـ Client!", reply_markup: keyboard)
      $client_states[chat_id][:state] = MAIN_MENU
    else
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض المشاكل", callback_data: "menu_show_tickets")]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "الرجاء اختيار خيار:", reply_markup: keyboard)
      $client_states[chat_id][:state] = MAIN_MENU
    end
  end

  def self.handle_callback_query(bot, callback_query)
    chat_id = callback_query.message.chat.id
    $client_states[chat_id] ||= {}
    data = callback_query.data
    case data
    when "menu_show_tickets"
      sub = DB.get_subscription(callback_query.from.id, "Client")
      client_name = sub ? sub["client"] : ""
      tickets = DB.get_all_open_tickets.select do |t|
        t["status"] == "Awaiting Client Response" && t["client"] == client_name
      end
      if tickets.any?
        tickets.each do |ticket|
          text = "<b>تذكرة ##{ticket['ticket_id']}</b>\n" +
                 "<b>رقم الطلب:</b> #{ticket['order_id']}\n" +
                 "<b>الوصف:</b> #{ticket['issue_description']}\n" +
                 "<b>الحالة:</b> #{ticket['status']}"
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: "حالياً", callback_data: "notify_pref|#{ticket['ticket_id']}|now")],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: "خلال 15 دقيقة", callback_data: "notify_pref|#{ticket['ticket_id']}|15")],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: "خلال 10 دقائق", callback_data: "notify_pref|#{ticket['ticket_id']}|10")],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: "حل المشكلة", callback_data: "solve|#{ticket['ticket_id']}")],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: "تجاهل", callback_data: "ignore|#{ticket['ticket_id']}")]
            ]
          )
          if ticket['image_url'] && !ticket['image_url'].empty?
            bot.api.send_photo(chat_id: chat_id, photo: ticket['image_url'])
          end
          safe_edit_message(bot, callback_query.message, text, keyboard)
        end
      else
        safe_edit_message(bot, callback_query.message, "لا توجد تذاكر في انتظار ردك.")
      end
    when /^notify_pref\|(\d+)\|(.*)/
      ticket_id = $1.to_i
      pref = $2
      if pref == "now"
        send_full_issue_details_to_client(bot, callback_query.message, ticket_id)
      else
        delay = (pref == "15" ? 900 : 600)
        Thread.new do
          sleep delay
          bot.api.send_message(chat_id: chat_id, text: "تذكير: لم تقم بالرد على التذكرة ##{ticket_id} بعد.")
        end
        send_issue_details_to_client(bot, callback_query.message, ticket_id)
      end
    when /^solve\|(\d+)/
      ticket_id = $1.to_i
      ticket = DB.get_ticket(ticket_id)
      if ["Client Responded", "Client Ignored", "Closed"].include?(ticket["status"])
        safe_edit_message(bot, callback_query.message, "التذكرة مغلقة أو تمت معالجتها بالفعل ولا يمكن تعديلها.")
      else
        $client_states[chat_id][:ticket_id] = ticket_id
        $client_states[chat_id][:state] = AWAITING_RESPONSE
        bot.api.send_message(chat_id: chat_id,
                             text: "أدخل الحل للمشكلة:",
                             reply_markup: Telegram::Bot::Types::ForceReply.new(selective: true))
      end
    when /^ignore\|(\d+)/
      ticket_id = $1.to_i
      ticket = DB.get_ticket(ticket_id)
      if ["Client Responded", "Client Ignored", "Closed"].include?(ticket["status"])
        safe_edit_message(bot, callback_query.message, "التذكرة مغلقة أو تمت معالجتها بالفعل ولا يمكن تعديلها.")
      else
        DB.update_ticket_status(ticket_id, "Client Ignored", { "action" => "client_ignored" })
        DB.update_ticket_status(ticket_id, "Client Responded", { "action" => "client_final_response", "message" => "ignored" })
        Notifier.notify_supervisors_client_response(ticket_id, ignored: true)
        safe_edit_message(bot, callback_query.message, "تم إرسال ردك (تم تجاهل التذكرة).")
      end
    else
      safe_edit_message(bot, callback_query.message, "الإجراء غير معروف.")
    end
  end

  def self.send_issue_details_to_client(bot, message, ticket_id)
    ticket = DB.get_ticket(ticket_id)
    text = "<b>تفاصيل التذكرة:</b>\n" +
           "رقم الطلب: #{ticket['order_id']}\n" +
           "الوصف: #{ticket['issue_description']}\n" +
           "الحالة: #{ticket['status']}"
    keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
      inline_keyboard: [
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "حالياً", callback_data: "notify_pref|#{ticket_id}|now")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "خلال 15 دقيقة", callback_data: "notify_pref|#{ticket_id}|15")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "خلال 10 دقائق", callback_data: "notify_pref|#{ticket_id}|10")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "حل المشكلة", callback_data: "solve|#{ticket_id}")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "تجاهل", callback_data: "ignore|#{ticket_id}")]
      ]
    )
    if ticket['image_url'] && !ticket['image_url'].empty?
      bot.api.send_photo(chat_id: message.chat.id, photo: ticket['image_url'])
    end
    safe_edit_message(bot, message, text, keyboard)
  end

  def self.send_full_issue_details_to_client(bot, message, ticket_id)
    ticket = DB.get_ticket(ticket_id)
    text = "<b>تفاصيل التذكرة الكاملة:</b>\n" +
           "رقم الطلب: #{ticket['order_id']}\n" +
           "الوصف: #{ticket['issue_description']}\n" +
           "الحالة: #{ticket['status']}"
    keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
      inline_keyboard: [
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "حل المشكلة", callback_data: "solve|#{ticket_id}")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: "تجاهل", callback_data: "ignore|#{ticket_id}")]
      ]
    )
    if ticket['image_url'] && !ticket['image_url'].empty?
      bot.api.send_photo(chat_id: message.chat.id, photo: ticket['image_url'])
    end
    safe_edit_message(bot, message, text, keyboard)
  end

  def self.run
    Telegram::Bot::Client.run(Config::CLIENT_BOT_TOKEN) do |bot|
      bot.api.deleteWebhook
      bot.listen do |message|
        case message
        when Telegram::Bot::Types::Message
          if message.text && message.text.start_with?('/start')
            start(bot, message)
          else
            handle_message(bot, message)
          end
        when Telegram::Bot::Types::CallbackQuery
          handle_callback_query(bot, message)
        end
      end
    end
  end
end
