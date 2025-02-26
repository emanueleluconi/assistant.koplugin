local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local queryChatGPT = require("gpt_query")

local CONFIGURATION = nil
local buttons, input_dialog = nil, nil

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- A small helper to fill placeholders in user_prompt (for custom prompts)
local function fillPlaceholders(template, doc_title, doc_author, highlight_text, extra_instructions)
  local s = template or ""
  s = s:gsub("{title}", doc_title or "")
  s = s:gsub("{author}", doc_author or "")
  s = s:gsub("{highlight}", highlight_text or "")
  s = s:gsub("{extra_input}", extra_instructions or "")
  return s
end

-- Common helper functions
local function showLoadingDialog()
  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1
  }
  UIManager:show(loading)
end

local function getBookContext(ui)
  return {
    title = ui.document:getProps().title or _("Unknown Title"),
    author = ui.document:getProps().authors or _("Unknown Author")
  }
end

local function createContextMessage(ui, highlightedText)
  local book = getBookContext(ui)
  return {
    role = "user",
    content = "I'm reading something titled '" .. book.title .. "' by " .. book.author ..
      ". I have a question about the following highlighted text: " .. highlightedText,
    is_context = true
  }
end

local function handleFollowUpQuestion(message_history, new_question, ui, highlightedText)
  local context_message = createContextMessage(ui, highlightedText)
  table.insert(message_history, context_message)

  local question_message = {
    role = "user",
    content = new_question
  }
  table.insert(message_history, question_message)

  local answer = queryChatGPT(message_history)
  local answer_message = {
    role = "assistant",
    content = answer
  }
  table.insert(message_history, answer_message)

  return message_history
end

local function createResultText(highlightedText, message_history, previous_text, show_highlighted_text)
  if not previous_text then
    local result_text = ""
    -- Possibly show highlighted text (unless config says to hide)
    if show_highlighted_text and 
       (not CONFIGURATION or 
        not CONFIGURATION.features or 
        not CONFIGURATION.features.hide_highlighted_text) then
      
      local should_show = true
      if CONFIGURATION and CONFIGURATION.features then
        if CONFIGURATION.features.hide_long_highlights and 
           CONFIGURATION.features.long_highlight_threshold and 
           (#highlightedText > CONFIGURATION.features.long_highlight_threshold) then
          should_show = false
        end
      end
      
      if should_show then
        result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
      end
    end
    
    -- Display user/assistant messages, skipping the initial context
    for i = 2, #message_history do
      if not message_history[i].is_context then
        if message_history[i].role == "user" then
          result_text = result_text .. "⮞ " .. _("User: ") .. message_history[i].content .. "\n"
        else
          result_text = result_text .. message_history[i].content .. "\n\n"
        end
      end
    end
    return result_text
  end

  -- If we had previous_text, just append the last user+assistant messages
  local last_user_message = message_history[#message_history - 1]
  local last_assistant_message = message_history[#message_history]

  if last_user_message and last_user_message.role == "user" and 
     last_assistant_message and last_assistant_message.role == "assistant" then
    local user_content = last_user_message.content or _("(Empty message)")
    local assistant_content = last_assistant_message.content or _("(No response)")
    return previous_text .. 
           "⮞ " .. _("User: ") .. user_content .. "\n" .. 
           "⮞ Assistant: " .. assistant_content .. "\n\n"
  end

  return previous_text
end

-- Helper function to create and show ChatGPT viewer
local function createAndShowViewer(ui, highlightedText, message_history, title, show_highlighted_text)
  show_highlighted_text = (show_highlighted_text == nil) and true or show_highlighted_text
  local result_text = createResultText(highlightedText, message_history, nil, show_highlighted_text)
  
  local chatgpt_viewer = ChatGPTViewer:new {
    title = _(title),
    text = result_text,
    ui = ui,
    onAskQuestion = function(viewer, new_question)
      NetworkMgr:runWhenOnline(function()
        local current_highlight = viewer.highlighted_text or highlightedText
        message_history = handleFollowUpQuestion(message_history, new_question, ui, current_highlight)
        local new_result_text = createResultText(current_highlight, message_history, viewer.text, false)
        viewer:update(new_result_text)
        
        if viewer.scroll_text_w then
          viewer.scroll_text_w:resetScroll()
        end
      end)
    end,
    highlighted_text = highlightedText,
    message_history = message_history
  }
  
  UIManager:show(chatgpt_viewer)
  
  if chatgpt_viewer.scroll_text_w then
    chatgpt_viewer.scroll_text_w:scrollToBottom()
  end
  
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.refresh_screen_after_displaying_results then
    UIManager:setDirty(nil, "full")
  end
end

-- Handle predefined prompt request
local function handlePredefinedPrompt(prompt_type, highlightedText, ui)
  if not CONFIGURATION or not CONFIGURATION.features or not CONFIGURATION.features.prompts then
    return nil, "No prompts configured"
  end

  local prompt = CONFIGURATION.features.prompts[prompt_type]
  if not prompt then
    return nil, "Prompt '" .. prompt_type .. "' not found"
  end

  local book = getBookContext(ui)
  -- The prompt_config.user_prompt is already updated with placeholders if needed.
  local formatted_user_prompt = (prompt.user_prompt or "Please analyze: ")
    :gsub("{title}", book.title)
    :gsub("{author}", book.author)
    :gsub("{highlight}", highlightedText)
    -- If user didn't provide extra instructions, it might remain {extra_input} in the string,
    -- but we won't forcibly remove it here unless you want:
    :gsub("{extra_input}", "")

  local message_history = {
    {
      role = "system",
      content = prompt.system_prompt or "You are a helpful assistant."
    },
    {
      role = "user",
      content = formatted_user_prompt,
      is_context = true
    }
  }
  
  local answer = queryChatGPT(message_history)
  if answer then
    table.insert(message_history, {
      role = "assistant",
      content = answer
    })
  end
  
  return message_history, nil
end

-- Main dialog function
local function showChatGPTDialog(ui, highlightedText, direct_prompt)
  if input_dialog then
    UIManager:close(input_dialog)
    input_dialog = nil
  end

  -- ----------------------------------------------------------
  -- 1) If a custom prompt was tapped, handle placeholders & input
  -- ----------------------------------------------------------
  if direct_prompt then
    local prompt_config = CONFIGURATION
      and CONFIGURATION.features
      and CONFIGURATION.features.prompts
      and CONFIGURATION.features.prompts[direct_prompt]

    if not prompt_config then
      UIManager:show(InfoMessage:new{text = _("Error: No such custom prompt configured")})
      return
    end

    -- If the custom prompt wants user input first
    if prompt_config.require_input then
      local extraInputDialog
      extraInputDialog = InputDialog:new{
        title = prompt_config.text or _("Custom Prompt"),
        input_hint = _("Enter any extra instructions here..."),
        input_type = "text",
        -- table-of-rows for the buttons
        buttons = {
          {
            {
              text = _("Cancel"),
              callback = function()
                UIManager:close(extraInputDialog)
              end
            },
            {
              text = _("Ask"),
              is_enter_default = true,
              callback = function()
                local userExtra = extraInputDialog:getInputText() or ""
                UIManager:close(extraInputDialog)

                -- Fill placeholders in user_prompt
                local doc = getBookContext(ui)
                local replaced_prompt = fillPlaceholders(
                  prompt_config.user_prompt,
                  doc.title,
                  doc.author,
                  highlightedText,
                  userExtra
                )

                -- Temporarily override the user_prompt
                local backup = prompt_config.user_prompt
                prompt_config.user_prompt = replaced_prompt

                showLoadingDialog()
                UIManager:scheduleIn(0.1, function()
                  local message_history, err = handlePredefinedPrompt(direct_prompt, highlightedText, ui)
                  -- restore original
                  prompt_config.user_prompt = backup

                  if err then
                    UIManager:show(InfoMessage:new{text = _("Error: " .. err)})
                    return
                  end
                  local title = prompt_config.text or _("Custom Prompt")
                  if not message_history or #message_history < 1 then
                    UIManager:show(InfoMessage:new{text = _("Error: No response received")})
                    return
                  end
                  createAndShowViewer(ui, highlightedText, message_history, title)
                end)
              end
            }
          }
        }
      }
      UIManager:show(extraInputDialog)
      extraInputDialog:onShowKeyboard()

    else
      -- If the prompt doesn't require extra user input, do placeholders with empty string
      local doc = getBookContext(ui)
      local replaced_prompt = fillPlaceholders(
        prompt_config.user_prompt,
        doc.title,
        doc.author,
        highlightedText,
        ""  -- no extra input
      )

      local backup = prompt_config.user_prompt
      prompt_config.user_prompt = replaced_prompt

      showLoadingDialog()
      UIManager:scheduleIn(0.1, function()
        local message_history, err = handlePredefinedPrompt(direct_prompt, highlightedText, ui)
        prompt_config.user_prompt = backup

        if err then
          UIManager:show(InfoMessage:new{text = _("Error: " .. err)})
          return
        end
        local title = prompt_config.text
        if not message_history or #message_history < 1 then
          UIManager:show(InfoMessage:new{text = _("Error: No response received")})
          return
        end
        createAndShowViewer(ui, highlightedText, message_history, title)
      end)
    end
    return
  end

  -- ----------------------------------------------------------
  -- 2) Otherwise, show the default “Assistant” input dialog
  -- (No placeholders for default Assistant)
  -- ----------------------------------------------------------
  local book = getBookContext(ui)
  local message_history = {{
    role = "system",
    content = CONFIGURATION.features.system_prompt 
             or "You are a helpful assistant for reading comprehension."
  }}

  -- Build the initial row of 3 or fewer columns
  local button_rows = {}
  local all_buttons = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        if input_dialog then
          UIManager:close(input_dialog)
          input_dialog = nil
        end
      end
    },
    {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        showLoadingDialog()
        UIManager:scheduleIn(0.1, function()
          local context_message = createContextMessage(ui, highlightedText)
          table.insert(message_history, context_message)

          local question_message = {
            role = "user",
            content = input_dialog and input_dialog:getInputText() or ""
          }
          table.insert(message_history, question_message)

          local answer = queryChatGPT(message_history)
          local answer_message = {
            role = "assistant",
            content = answer
          }
          table.insert(message_history, answer_message)

          if input_dialog then
            UIManager:close(input_dialog)
            input_dialog = nil
          end
          
          createAndShowViewer(ui, highlightedText, message_history, "Assistant")
        end)
      end
    }
  }
  
  -- Possibly add a "Dictionary" button if configured
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.dictionary_translate_to then
    table.insert(all_buttons, {
      text = _("Dictionary"),
      callback = function()
        if input_dialog then
          UIManager:close(input_dialog)
          input_dialog = nil
        end
        showLoadingDialog()
        UIManager:scheduleIn(0.1, function()
          local showDictionaryDialog = require("dictdialog")
          showDictionaryDialog(ui, highlightedText)
        end)
      end
    })
  end

  -- Next, add custom prompt buttons (the immediate flow, no placeholders here)
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
    local sorted_prompts = {}
    for prompt_type, prompt in pairs(CONFIGURATION.features.prompts) do
      table.insert(sorted_prompts, {type = prompt_type, config = prompt})
    end
    table.sort(sorted_prompts, function(a, b)
      local order_a = a.config.order or 1000
      local order_b = b.config.order or 1000
      return order_a < order_b
    end)
    
    for idx, prompt_data in ipairs(sorted_prompts) do
      local ptype = prompt_data.type
      local p = prompt_data.config
      table.insert(all_buttons, {
        text = _(p.text),
        callback = function()
          UIManager:close(input_dialog)
          input_dialog = nil
          showLoadingDialog()
          UIManager:scheduleIn(0.1, function()
            local message_history, err = handlePredefinedPrompt(ptype, highlightedText, ui)
            if err then
              UIManager:show(InfoMessage:new{text = _("Error: " .. err)})
              return
            end
            createAndShowViewer(ui, highlightedText, message_history, p.text)
          end)
        end
      })
    end
  end
  
  -- Group them into rows of 3
  local current_row = {}
  for _, button in ipairs(all_buttons) do
    table.insert(current_row, button)
    if #current_row == 3 then
      table.insert(button_rows, current_row)
      current_row = {}
    end
  end
  
  if #current_row > 0 then
    table.insert(button_rows, current_row)
  end

  -- Create the main input dialog
  input_dialog = InputDialog:new{
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons = button_rows,
    close_callback = function()
      if input_dialog then
        UIManager:close(input_dialog)
        input_dialog = nil
      end
    end,
    dismiss_callback = function()
      if input_dialog then
        UIManager:close(input_dialog)
        input_dialog = nil
      end
    end
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

return showChatGPTDialog
