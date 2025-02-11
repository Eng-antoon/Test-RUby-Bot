require 'telegram/bot'
require 'net/http'
require 'json'
require 'uri'
require 'cgi'
require 'cloudinary'
require 'cloudinary/uploader'
require_relative 'config'
require_relative 'db'
require_relative 'notifier'

# Configure Cloudinary
Cloudinary.config(
  cloud_name: Config::CLOUDINARY_CLOUD_NAME,
  api_key: Config::CLOUDINARY_API_KEY,
  api_secret: Config::CLOUDINARY_API_SECRET
)

module DaBot
  # Conversation state constants
  SUBSCRIPTION_PHONE      = 0
  MAIN_MENU               = 1
  NEW_ISSUE_ORDER         = 2
  NEW_ISSUE_DESCRIPTION   = 3
  NEW_ISSUE_REASON        = 4
  NEW_ISSUE_TYPE          = 5
  ASK_IMAGE               = 6
  WAIT_IMAGE              = 7
  EDIT_PROMPT             = 8
  EDIT_FIELD              = 9
  MORE_INFO_PROMPT        = 10
  NEW_ISSUE_ORDER_MANUAL  = 11   # For manual order entry when no orders are returned

  $da_states = {}

  ISSUE_OPTIONS = {
    "المخزن" => ["تالف", "منتهي الصلاحية", "عجز في المخزون", "تحضير خاطئ"],
    "المورد"  => ["خطا بالمستندات", "رصيد غير موجود", "اوردر خاطئ", "اوردر بكميه اكبر",
                  "خطا فى الباركود او اسم الصنف", "اوردر وهمى", "خطأ فى الاسعار",
                  "تخطى وقت الانتظار لدى العميل", "اختلاف بيانات الفاتورة", "توالف مصنع"],
    "العميل"  => ["رفض الاستلام", "مغلق", "عطل بالسيستم", "لا يوجد مساحة للتخزين", "شك عميل فى سلامة العبوه"],
    "التسليم" => ["وصول متاخر", "تالف", "عطل بالسياره"]
  }

  # A helper that edits the message safely—if the original message was a photo message (has a caption),
  # it uses editMessageCaption; otherwise, it uses editMessageText.
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

  # finalize_ticket: creates the ticket in the database and notifies supervisors.
  def self.finalize_ticket(bot, message, data)
    order_id    = data[:order_id]
    description = data[:description]
    issue_reason = data[:issue_reason]
    issue_type   = data[:issue_type]
    client      = data[:client]
    image_url   = data[:image] || ""
    da_id       = message.from.id
    ticket_id = DB.add_ticket(order_id, description, issue_reason, issue_type, client, image_url, "Opened", da_id)
    bot.api.send_message(chat_id: message.chat.id, text: "تم إنشاء التذكرة برقم #{ticket_id}.\nالحالة: Opened")
    ticket = DB.get_ticket(ticket_id)
    Notifier.notify_supervisors(ticket)
    $da_states[message.chat.id] = {}  # Clear the state.
  end

  # -----------------------------------------------------------------------------
  # fetch_orders: Contacts the external API to retrieve orders.
  def self.fetch_orders(bot, message, user)
    sub = DB.get_subscription(user.id, "DA")
    unless sub && sub["phone"] && !sub["phone"].empty?
      safe_edit_message(bot, message, "لم يتم العثور على بيانات الاشتراك أو رقم الهاتف.")
      $da_states[message.chat.id] ||= {}
      $da_states[message.chat.id][:state] = MAIN_MENU
      return
    end
    agent_phone = sub["phone"]
    # Using the fixed date as in the Python code.
    url = "https://3e5440qr0c.execute-api.eu-west-3.amazonaws.com/dev/locus_info?agent_phone=#{agent_phone}&order_date='2024-11-05'"
    begin
      uri = URI(url)
      response = Net::HTTP.get(uri)
      orders_data = JSON.parse(response)
      orders = orders_data["data"] || []
      $da_states[message.chat.id] ||= {}
      if orders.any?
        buttons = orders.map do |order|
          order_id    = order["order_id"]
          client_name = order["client_name"]
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "طلب #{order_id} - #{client_name}",
            callback_data: "select_order|#{order_id}|#{client_name}"
          )
        end
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: buttons.map { |b| [b] }
        )
        safe_edit_message(bot, message, "اختر الطلب الذي تريد رفع مشكلة عنه:", keyboard)
        $da_states[message.chat.id][:state] = NEW_ISSUE_ORDER
      else
        safe_edit_message(bot, message, "لا توجد طلبات اليوم. يرجى إدخال رقم الطلب والعميل يدويًا (مثال: 12345,بيبس):")
        $da_states[message.chat.id][:state] = NEW_ISSUE_ORDER_MANUAL
      end
    rescue => e
      safe_edit_message(bot, message, "حدث خطأ أثناء جلب الطلبات: #{e}")
      $da_states[message.chat.id] ||= {}
      $da_states[message.chat.id][:state] = MAIN_MENU
    end
  end

  # -----------------------------------------------------------------------------
  # da_start: Handles the /start command.
  def self.da_start(bot, message)
    user = message.from
    sub = DB.get_subscription(user.id, "DA")
    chat_id = message.chat.id
    if sub.nil?
      bot.api.send_message(chat_id: chat_id, text: "أهلاً! يرجى إدخال رقم هاتفك للاشتراك (DA):")
      $da_states[chat_id] = { state: SUBSCRIPTION_PHONE }
    else
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "إضافة مشكلة", callback_data: "menu_add_issue"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "استعلام عن مشكلة", callback_data: "menu_query_issue")
          ]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "مرحباً #{user.first_name}", reply_markup: keyboard)
      $da_states[chat_id] = { state: MAIN_MENU }
    end
  end

  # -----------------------------------------------------------------------------
  # da_handle_message: Handles incoming text messages.
  def self.da_handle_message(bot, message)
    chat_id = message.chat.id
    $da_states[chat_id] ||= {}
    state_info = $da_states[chat_id]
    case state_info[:state]
    when SUBSCRIPTION_PHONE
      phone = message.text.strip
      user = message.from
      DB.add_subscription(user.id, phone, "DA", "DA", nil,
                          user.username, user.first_name, user.last_name, chat_id)
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "إضافة مشكلة", callback_data: "menu_add_issue"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "استعلام عن مشكلة", callback_data: "menu_query_issue")
          ]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "تم الاشتراك بنجاح كـ DA!", reply_markup: keyboard)
      $da_states[chat_id][:state] = MAIN_MENU
    when NEW_ISSUE_ORDER_MANUAL
      # Expect manual entry in the format: order_id,client_name
      manual = message.text.strip
      parts = manual.split(",")
      if parts.size >= 2
        order_id = parts[0].strip
        client_name = parts[1].strip
        $da_states[chat_id][:order_id] = order_id
        $da_states[chat_id][:client] = client_name
        safe_edit_message(bot, message, "تم إدخال الطلب رقم #{order_id} للعميل #{client_name}.\nالآن، صف المشكلة التي تواجهها:")
        $da_states[chat_id][:state] = NEW_ISSUE_DESCRIPTION
      else
        bot.api.send_message(chat_id: chat_id, text: "صيغة الإدخال غير صحيحة. يرجى استخدام الصيغة: رقم الطلب,اسم العميل")
      end
    when NEW_ISSUE_DESCRIPTION
      description = message.text.strip
      $da_states[chat_id][:description] = description
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "المخزن", callback_data: "issue_reason_المخزن"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "المورد", callback_data: "issue_reason_المورد")
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "العميل", callback_data: "issue_reason_العميل"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "التسليم", callback_data: "issue_reason_التسليم")
          ]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "اختر سبب المشكلة:", reply_markup: keyboard)
      $da_states[chat_id][:state] = NEW_ISSUE_REASON
    when WAIT_IMAGE
      if message.photo && !message.photo.empty?
        photo = message.photo.last
        file_id = photo.file_id
        file = bot.api.get_file(file_id: file_id)
        file_path = file.file_path  # Use file.file_path instead of file["result"]["file_path"]
        file_url = "https://api.telegram.org/file/bot#{Config::DA_BOT_TOKEN}/#{file_path}"
        begin
          result = Cloudinary::Uploader.upload(file_url)
          secure_url = result["secure_url"]
          $da_states[chat_id][:image] = secure_url
          show_ticket_summary_for_edit(bot, message, $da_states[chat_id])
          $da_states[chat_id][:state] = EDIT_PROMPT
        rescue => e
          bot.api.send_message(chat_id: chat_id, text: "فشل رفع الصورة. حاول مرة أخرى:")
        end
      else
        bot.api.send_message(chat_id: chat_id, text: "لم يتم إرسال صورة صحيحة. أعد الإرسال:")
      end
    else
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "إضافة مشكلة", callback_data: "menu_add_issue"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: "استعلام عن مشكلة", callback_data: "menu_query_issue")
          ]
        ]
      )
      bot.api.send_message(chat_id: chat_id, text: "الرجاء اختيار خيار:", reply_markup: keyboard)
      $da_states[chat_id][:state] = MAIN_MENU
    end
  end

  # -----------------------------------------------------------------------------
  # da_handle_callback_query: Handles button presses.
  def self.da_handle_callback_query(bot, callback_query)
    chat_id = callback_query.message.chat.id
    $da_states[chat_id] ||= {}
    data = callback_query.data
    if data == "menu_add_issue"
      fetch_orders(bot, callback_query.message, callback_query.from)
    elsif data == "menu_query_issue"
      user = callback_query.from
      tickets = DB.get_all_tickets.select { |t| t["da_id"] == user.id }
      if tickets.any?
        tickets.each do |ticket|
          status_mapping = {
            "Opened" => "مفتوحة",
            "Pending DA Action" => "في انتظار إجراء الوكيل",
            "Awaiting Client Response" => "في انتظار رد العميل",
            "Client Responded" => "تم رد العميل",
            "Client Ignored" => "تم تجاهل العميل",
            "Closed" => "مغلقة",
            "Additional Info Provided" => "تم توفير معلومات إضافية",
            "Pending DA Response" => "في انتظار رد الوكيل"
          }
          status_ar = status_mapping[ticket["status"]] || ticket["status"]
          resolution = ticket["status"] == "Closed" ? "\nالحل: تم الحل." : ""
          text = "<b>تذكرة ##{ticket['ticket_id']}</b>\n" +
                 "<b>رقم الطلب:</b> #{ticket['order_id']}\n" +
                 "<b>الوصف:</b> #{ticket['issue_description']}\n" +
                 "<b>سبب المشكلة:</b> #{ticket['issue_reason']}\n" +
                 "<b>نوع المشكلة:</b> #{ticket['issue_type']}\n" +
                 "<b>الحالة:</b> #{status_ar}#{resolution}"
          bot.api.send_message(chat_id: chat_id, text: text, parse_mode: "HTML")
        end
      else
        safe_edit_message(bot, callback_query.message, "لا توجد تذاكر.")
      end
    elsif data.start_with?("select_order|")
      parts = data.split("|")
      if parts.length < 3
        safe_edit_message(bot, callback_query.message, "بيانات الطلب غير صحيحة.")
        return
      end
      order_id = parts[1]
      client_name = parts[2]
      $da_states[chat_id][:order_id] = order_id
      $da_states[chat_id][:client] = client_name
      safe_edit_message(bot, callback_query.message,
                        "تم اختيار الطلب رقم #{order_id} للعميل #{client_name}.\nالآن، صف المشكلة التي تواجهها:")
      $da_states[chat_id][:state] = NEW_ISSUE_DESCRIPTION
    elsif data.start_with?("issue_reason_")
      # For example, data = "issue_reason_المورد"
      reason = data.split("_", 3)[2]
      $da_states[chat_id][:issue_reason] = reason
      types = ISSUE_OPTIONS[reason] || []
      buttons = types.map do |t|
        [Telegram::Bot::Types::InlineKeyboardButton.new(
          text: t,
          callback_data: "it_" + t   # Use raw text; ensure its UTF-8 byte length is below 64 bytes.
        )]
      end
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
      safe_edit_message(bot, callback_query.message, "اختر نوع المشكلة:", keyboard)
      $da_states[chat_id][:state] = NEW_ISSUE_TYPE
    elsif data.start_with?("it_")
      issue_type = data[3..-1]
      $da_states[chat_id][:issue_type] = issue_type
      buttons = [
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "نعم", callback_data: "attach_yes"),
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "لا", callback_data: "attach_no")
        ]
      ]
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
      safe_edit_message(bot, callback_query.message, "هل تريد إرفاق صورة للمشكلة؟", keyboard)
      $da_states[chat_id][:state] = ASK_IMAGE
    elsif data == "attach_yes"
      safe_edit_message(bot, callback_query.message, "يرجى إرسال الصورة:")
      $da_states[chat_id][:state] = WAIT_IMAGE
    elsif data == "attach_no"
      show_ticket_summary_for_edit(bot, callback_query.message, $da_states[chat_id])
      $da_states[chat_id][:state] = EDIT_PROMPT
    elsif data == "edit_ticket_no"
      finalize_ticket(bot, callback_query.message, $da_states[chat_id])
    elsif data == "edit_ticket_yes"
      bot.api.send_message(chat_id: chat_id, text: "ميزة التعديل غير مفعلة حاليًا. التذكرة ستُرسل كما هي.")
      finalize_ticket(bot, callback_query.message, $da_states[chat_id])
    else
      safe_edit_message(bot, callback_query.message, "الخيار غير معروف.")
    end
  end

  # -----------------------------------------------------------------------------
  # show_ticket_summary_for_edit: Displays a summary of the entered issue.
  def self.show_ticket_summary_for_edit(bot, message, data)
    summary = "رقم الطلب: #{data[:order_id]}\n" +
              "الوصف: #{data[:description]}\n" +
              "سبب المشكلة: #{data[:issue_reason]}\n" +
              "نوع المشكلة: #{data[:issue_type]}\n" +
              "العميل: #{data[:client]}\n" +
              "الصورة: #{data[:image] || 'لا توجد'}"
    text = "ملخص التذكرة المدخلة:\n" + summary + "\nهل تريد تعديل التذكرة قبل الإرسال؟"
    keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
      inline_keyboard: [
        [
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "نعم", callback_data: "edit_ticket_yes"),
          Telegram::Bot::Types::InlineKeyboardButton.new(text: "لا", callback_data: "edit_ticket_no")
        ]
      ]
    )
    bot.api.send_message(chat_id: message.chat.id, text: text, reply_markup: keyboard)
  end

  def self.da_bot_main
    Telegram::Bot::Client.run(Config::DA_BOT_TOKEN) do |bot|
      bot.listen do |message|
        case message
        when Telegram::Bot::Types::Message
          if message.text && message.text.start_with?('/start')
            da_start(bot, message)
          else
            da_handle_message(bot, message)
          end
        when Telegram::Bot::Types::CallbackQuery
          da_handle_callback_query(bot, message)
        end
      end
    end
  end

  def self.run
    da_bot_main
  end
end
