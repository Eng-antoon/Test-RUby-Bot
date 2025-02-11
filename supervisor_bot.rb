# supervisor_bot.rb
require 'telegram/bot'
require 'json'
require_relative 'db'
require_relative 'config'
require_relative 'notifier'

module SupervisorBot
  $user_states = {}

  SUBSCRIPTION_PHONE = :subscription_phone
  MAIN_MENU         = :main_menu
  SEARCH_TICKETS    = :search_tickets
  AWAITING_RESPONSE = :awaiting_response

  def self.set_state(user_id, state, data = {})
    $user_states[user_id] = { state: state }.merge(data)
  end

  def self.get_state(user_id)
    $user_states[user_id] || { state: MAIN_MENU }
  end

  def self.clear_state(user_id)
    $user_states.delete(user_id)
  end

  def self.safe_edit_message(bot, callback_query, text, reply_markup = nil)
    message = callback_query.message
    if message.respond_to?(:caption) && message.caption && !message.caption.empty?
      bot.api.editMessageCaption(
        chat_id: message.chat.id,
        message_id: message.message_id,
        caption: text,
        reply_markup: reply_markup,
        parse_mode: 'HTML'
      )
    else
      bot.api.editMessageText(
        chat_id: message.chat.id,
        message_id: message.message_id,
        text: text,
        reply_markup: reply_markup,
        parse_mode: 'HTML'
      )
    end
  end

  def self.send_main_menu(bot, chat_id)
    keyboard = [
      [
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض الكل", callback_data: "menu_show_all"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "استعلام عن مشكلة", callback_data: "menu_query_issue")
      ]
    ]
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
    bot.api.send_message(chat_id: chat_id, text: "الرجاء اختيار خيار:", reply_markup: markup)
    set_state(chat_id, MAIN_MENU)
  end

  def self.process_start(bot, message)
    user = message.from
    subscription = DB.get_subscription(user.id, "Supervisor")
    if subscription.nil?
      bot.api.send_message(chat_id: message.chat.id, text: "أهلاً! يرجى إدخال رقم هاتفك للاشتراك (Supervisor):")
      set_state(user.id, SUBSCRIPTION_PHONE)
    else
      send_main_menu(bot, message.chat.id)
    end
  end

  def self.process_subscription_phone(bot, message)
    phone = message.text.strip
    user = message.from
    DB.add_subscription(user.id, phone, 'Supervisor', "Supervisor", nil,
                        user.username, user.first_name, user.last_name, message.chat.id)
    keyboard = [
      [
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض الكل", callback_data: "menu_show_all"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "استعلام عن مشكلة", callback_data: "menu_query_issue")
      ]
    ]
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
    bot.api.send_message(chat_id: message.chat.id, text: "تم الاشتراك بنجاح كـ Supervisor!", reply_markup: markup)
    set_state(user.id, MAIN_MENU)
  end

  def self.process_search_tickets(bot, message, state)
    query_text = message.text.strip
    tickets = DB.search_tickets_by_order(query_text)
    if tickets.any?
      tickets.each do |ticket|
        text = "<b>تذكرة ##{ticket['ticket_id']}</b>\n" \
               "رقم الطلب: #{ticket['order_id']}\n" \
               "العميل: #{ticket['client']}\n" \
               "الوصف: #{ticket['issue_description']}\n" \
               "الحالة: #{ticket['status']}"
        keyboard = [
          [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض التفاصيل", callback_data: "view|#{ticket['ticket_id']}")]
        ]
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
        bot.api.send_message(chat_id: message.chat.id, text: text, reply_markup: markup, parse_mode: 'HTML')
      end
    else
      bot.api.send_message(chat_id: message.chat.id, text: "لم يتم العثور على تذاكر مطابقة.")
    end
    send_main_menu(bot, message.chat.id)
  end

  def self.process_awaiting_response(bot, message, state)
    response = message.text.strip
    user_state = get_state(message.from.id)
    ticket_id = user_state[:ticket_id]
    action    = user_state[:action]

    if ticket_id.nil? || action.nil?
      bot.api.send_message(chat_id: message.chat.id, text: "حدث خطأ. أعد المحاولة.")
      set_state(message.from.id, MAIN_MENU)
      return
    end

    if action == 'solve'
      DB.update_ticket_status(ticket_id, "Pending DA Action", {"action" => "supervisor_solution", "message" => response})
      # Notify DA using Notifier (which uses the DA bot token)
      ticket = DB.get_ticket(ticket_id)
      Notifier.notify_da(ticket)
      bot.api.send_message(chat_id: message.chat.id, text: "تم إرسال الحل إلى الوكيل.")
    elsif action == 'moreinfo'
      DB.update_ticket_status(ticket_id, "Pending DA Response", {"action" => "request_more_info", "message" => response})
      ticket = DB.get_ticket(ticket_id)
      Notifier.notify_da(ticket)
      bot.api.send_message(chat_id: message.chat.id, text: "تم إرسال الطلب إلى الوكيل.")
    end

    clear_state(message.from.id)
    send_main_menu(bot, message.chat.id)
  end

  def self.send_to_client(ticket_id, bot, chat_id)
    ticket = DB.get_ticket(ticket_id)
    Notifier.notify_client(ticket)
    bot.api.send_message(chat_id: chat_id, text: "تم إرسال التذكرة إلى العميل.")
  end

  def self.process_callback_query(bot, callback_query)
    data    = callback_query.data
    chat_id = callback_query.message.chat.id
    user_id = callback_query.from.id

    case data
    when "menu_show_all"
      tickets = DB.get_all_open_tickets
      if tickets.any?
        tickets.each do |ticket|
          text = "<b>تذكرة ##{ticket['ticket_id']}</b>\n" +
                 "رقم الطلب: #{ticket['order_id']}\n" +
                 "العميل: #{ticket['client']}\n" +
                 "الوصف: #{ticket['issue_description']}\n" +
                 "الحالة: #{ticket['status']}"
          keyboard = [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "عرض التفاصيل", callback_data: "view|#{ticket['ticket_id']}")]
          ]
          markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
          if ticket['image_url'] && !ticket['image_url'].empty?
            bot.api.send_photo(chat_id: chat_id, photo: ticket['image_url'], caption: text, reply_markup: markup, parse_mode: "HTML")
          else
            safe_edit_message(bot, callback_query, text, markup)
          end
        end
      else
        safe_edit_message(bot, callback_query, "لا توجد تذاكر مفتوحة حالياً.")
      end
      set_state(user_id, MAIN_MENU)

    when "menu_query_issue"
      safe_edit_message(bot, callback_query, "أدخل رقم الطلب:")
      set_state(user_id, SEARCH_TICKETS)

    else
      if data.start_with?("view|")
        parts = data.split("|")
        ticket_id = parts[1].to_i
        ticket = DB.get_ticket(ticket_id)
        if ticket
          logs = ""
          begin
            if ticket["logs"] && !ticket["logs"].empty?
              logs_list = JSON.parse(ticket["logs"])
              logs = logs_list.map { |entry| "#{entry['timestamp']}: #{entry['action']} - #{entry['message']}" }.join("\n")
            end
          rescue
            logs = "لا توجد سجلات إضافية."
          end
          text = "<b>تفاصيل التذكرة ##{ticket['ticket_id']}</b>\n" +
                 "رقم الطلب: #{ticket['order_id']}\n" +
                 "العميل: #{ticket['client']}\n" +
                 "الوصف: #{ticket['issue_description']}\n" +
                 "سبب المشكلة: #{ticket['issue_reason']}\n" +
                 "نوع المشكلة: #{ticket['issue_type']}\n" +
                 "الحالة: #{ticket['status']}\n\n" +
                 "السجلات:\n#{logs}"
          keyboard = []
          keyboard << Telegram::Bot::Types::InlineKeyboardButton.new(text: "إرسال للحالة إلى الوكيل", callback_data: "sendto_da|#{ticket_id}") if ticket["status"] == "Client Responded"
          keyboard += [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "حل المشكلة", callback_data: "solve|#{ticket_id}"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "طلب المزيد من المعلومات", callback_data: "moreinfo|#{ticket_id}"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "إرسال إلى العميل", callback_data: "sendclient|#{ticket_id}")
          ]
          markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [keyboard])
          safe_edit_message(bot, callback_query, text, markup)
        else
          safe_edit_message(bot, callback_query, "التذكرة غير موجودة.")
        end
        set_state(user_id, MAIN_MENU)

      elsif data.start_with?("solve|")
        ticket_id = data.split("|")[1].to_i
        set_state(user_id, AWAITING_RESPONSE, ticket_id: ticket_id, action: 'solve')
        bot.api.send_message(
          chat_id: chat_id,
          text: "أدخل رسالة الحل للمشكلة:",
          reply_markup: Telegram::Bot::Types::ForceReply.new(force_reply: true, selective: true)
        )

      elsif data.start_with?("moreinfo|")
        ticket_id = data.split("|")[1].to_i
        set_state(user_id, AWAITING_RESPONSE, ticket_id: ticket_id, action: 'moreinfo')
        bot.api.send_message(
          chat_id: chat_id,
          text: "أدخل المعلومات الإضافية المطلوبة:",
          reply_markup: Telegram::Bot::Types::ForceReply.new(force_reply: true, selective: true)
        )

      elsif data.start_with?("sendclient|")
        ticket_id = data.split("|")[1].to_i
        send_to_client(ticket_id, bot, chat_id)
        safe_edit_message(bot, callback_query, "تم إرسال التذكرة إلى العميل.")
        set_state(user_id, MAIN_MENU)

      elsif data.start_with?("confirm_sendclient|")
        ticket_id = data.split("|")[1].to_i
        send_to_client(ticket_id, bot, chat_id)
        safe_edit_message(bot, callback_query, "تم إرسال التذكرة إلى العميل.")
        set_state(user_id, MAIN_MENU)

      elsif data.start_with?("cancel_sendclient|")
        safe_edit_message(bot, callback_query, "تم إلغاء الإرسال إلى العميل.")
        set_state(user_id, MAIN_MENU)

      elsif data.start_with?("sendto_da|")
        ticket_id = data.split("|")[1].to_i
        keyboard = [
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "نعم", callback_data: "confirm_sendto_da|#{ticket_id}"),
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "لا", callback_data: "cancel_sendto_da|#{ticket_id}")
        ]
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [keyboard])
        safe_edit_message(bot, callback_query, "هل أنت متأكد من إرسال الحل إلى الوكيل؟", markup)
        set_state(user_id, MAIN_MENU)

      elsif data.start_with?("confirm_sendto_da|")
        ticket_id = data.split("|")[1].to_i
        ticket = DB.get_ticket(ticket_id)
        client_solution = nil
        if ticket["logs"] && !ticket["logs"].empty?
          begin
            logs_list = JSON.parse(ticket["logs"])
            logs_list.each do |log|
              if log["action"] == "client_solution"
                client_solution = log["message"]
                break
              end
            end
          rescue
            client_solution = nil
          end
        end
        client_solution ||= "لا يوجد حل من العميل."
        DB.update_ticket_status(ticket_id, "Pending DA Action", {"action" => "supervisor_forward", "message" => client_solution})
        ticket = DB.get_ticket(ticket_id)
        Notifier.notify_da(ticket)
        safe_edit_message(bot, callback_query, "تم إرسال التذكرة إلى الوكيل.")
        set_state(user_id, MAIN_MENU)

      elsif data.start_with?("cancel_sendto_da|")
        safe_edit_message(bot, callback_query, "تم إلغاء إرسال التذكرة إلى الوكيل.")
        set_state(user_id, MAIN_MENU)

      else
        safe_edit_message(bot, callback_query, "الإجراء غير معروف.")
        set_state(user_id, MAIN_MENU)
      end
    end
  end

  def self.run
    Telegram::Bot::Client.run(Config::SUPERVISOR_BOT_TOKEN) do |bot|
      bot.api.deleteWebhook
      bot.listen do |message|
        case message
        when Telegram::Bot::Types::Message
          if message.text
            user_state = get_state(message.from.id)
            case user_state[:state]
            when SUBSCRIPTION_PHONE
              process_subscription_phone(bot, message)
            when SEARCH_TICKETS
              process_search_tickets(bot, message, user_state)
            when AWAITING_RESPONSE
              process_awaiting_response(bot, message, user_state)
            else
              if message.text == '/start'
                process_start(bot, message)
              else
                send_main_menu(bot, message.chat.id)
              end
            end
          end
        when Telegram::Bot::Types::CallbackQuery
          process_callback_query(bot, message)
        end
      end
    end
  end
end
