# frozen_string_literal: true

require "selenium-webdriver"

module Haiku55Http
  # The same form, canvas JPEG, HTTP endpoint, and cable rendering a technician uses.
  class PhotoBrowser
    INPUT = 'textarea[data-rag-chat-target="input"]'
    ROW = '.chat-row-assistant'
    TERMINAL = %w[photo_question_answered photo_analyzed failed].freeze

    def initialize(port, host, user, password)
      @url = "http://#{host}:#{port}"
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless=new")
      options.add_argument("--window-size=1100,900")
      options.add_argument("--no-proxy-server")
      options.add_argument("--disable-background-networking")
      options.add_argument("--host-resolver-rules=MAP #{host} 127.0.0.1")
      # An installed driver can be supplied for machines with offline Chrome.
      path = ENV["HTTP55_CHROMEDRIVER"].presence
      service = Selenium::WebDriver::Service.chrome(path: path) if path
      @driver = Selenium::WebDriver.for(:chrome, options: options, service: service)
      @wait = Selenium::WebDriver::Wait.new(timeout: 180, interval: 0.15)
      @driver.navigate.to("#{@url}/users/sign_in")
      @driver.find_element(id: "user_email").send_keys(user.email)
      @driver.find_element(id: "user_password").send_keys(password)
      @driver.find_element(css: 'form input[type="submit"], form button[type="submit"]').click
      @wait.until { chat_ready? }
      @driver.execute_script(<<~JS)
        const original = window.fetch;
        window.auditAsk = null;
        window.fetch = async function(input, options) {
          const response = await original.call(this, input, options);
          if (input === "/rag/ask") {
            const copy = response.clone();
            const body = await copy.json().catch(() => null);
            window.auditAsk = {status: copy.status, request_id: copy.headers.get("X-Request-Id"), json: body};
          }
          return response;
        };
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="rag-chat"]'), "rag-chat");
        const subscription = ctrl.kbSyncSubscription;
        const received = subscription.received;
        subscription.received = function(payload) {
          if (ctrl.matchesPendingPhoto(payload)) window.auditPhotoDelivery = payload;
          return received.call(this, payload);
        };
      JS
    rescue StandardError
      close
      raise
    end

    def send_turn(question, photo: nil)
      @row_count = @driver.find_elements(css: ROW).size
      @driver.execute_script("window.auditAsk = null; window.auditPhotoDelivery = null")
      if photo
        @driver.find_element(css: 'input[data-rag-chat-target="fileInput"]').send_keys(photo)
        @wait.until { @driver.find_element(css: '[data-rag-chat-target="imageThumb"]').displayed? }
      end
      @driver.find_element(css: INPUT).send_keys(question)
      @driver.find_element(css: '.chat-composer-form button[type="submit"]').click
      @wait.until { @driver.execute_script("return window.auditAsk") }.symbolize_keys
    end

    def photo_acknowledged?(correlation)
      @wait.until do
        @driver.execute_script(<<~JS, correlation)
          return window.Stimulus.getControllerForElementAndIdentifier(
            document.querySelector('[data-controller~="rag-chat"]'), "rag-chat"
          ).pendingPhotoCorrelationId === arguments[0];
        JS
      end
    end

    def photo_delivery
      @wait.until do
        data = @driver.execute_script("return window.auditPhotoDelivery")
        data if data && TERMINAL.include?(data["status"])
      end
    end

    def save_turn(path)
      row = @wait.until do
        rows = @driver.find_elements(css: ROW)
        rows.last if rows.size > @row_count && rows.last.displayed?
      end
      @driver.execute_script("arguments[0].scrollIntoView({block: 'center'})", row)
      @driver.save_screenshot(path.join("ui.png").to_s)
      File.write(path.join("ui.txt"), row.text)
    rescue Selenium::WebDriver::Error::TimeoutError
      @driver.save_screenshot(path.join("ui.png").to_s)
      File.write(path.join("ui.txt"), @driver.find_element(tag_name: "body").text)
    end

    def close
      @driver&.quit
    end

    private

    def chat_ready?
      @driver.execute_script(<<~JS)
        const element = document.querySelector('[data-controller~="rag-chat"]');
        const ctrl = element && window.Stimulus?.getControllerForElementAndIdentifier(element, "rag-chat");
        const sub = ctrl?.kbSyncSubscription;
        return !!sub?.consumer.connection.isOpen() && !sub.consumer.subscriptions.guarantor.pendingSubscriptions.includes(sub);
      JS
    end
  end
end
