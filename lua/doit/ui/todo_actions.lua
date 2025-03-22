local vim = vim

local state = require("doit.state")
local config = require("doit.config")
local calendar = require("doit.calendar")

local M = {}

-- Local helper: parse time estimation (ex: "30m", "2h", "1.5d")
function M.parse_time_estimation(time_str)
	local number, unit = time_str:match("^(%d+%.?%d*)([mhdw])$")
	if not (number and unit) then
		return nil, "Invalid format. Use number followed by m/h/d/w (e.g. 30m, 2h, 1d, 0.5w)"
	end

	local hours = tonumber(number)
	if not hours then
		return nil, "Invalid number format"
	end

	if unit == "m" then
		hours = hours / 60
	elseif unit == "d" then
		hours = hours * 24
	elseif unit == "w" then
		hours = hours * 24 * 7
	end

	return hours
end

--------------------------------------------------
-- Priority Selection Helper
--------------------------------------------------
local function cleanup_priority_selection(select_buf, select_win, keymaps)
	for _, keymap in ipairs(keymaps) do
		pcall(vim.keymap.del, "n", keymap, { buffer = select_buf })
	end
	if select_win and vim.api.nvim_win_is_valid(select_win) then
		vim.api.nvim_win_close(select_win, true)
	end
	if select_buf and vim.api.nvim_buf_is_valid(select_buf) then
		vim.api.nvim_buf_delete(select_buf, { force = true })
	end
end

--------------------------------------------------
-- Todo Actions
--------------------------------------------------

-- Create a new to-do. Because we no longer call "render_todos()" directly here,
-- we allow the caller to do so after the new to-do is created (to avoid circular requires).
function M.new_todo(on_render)
	vim.ui.input({ prompt = "New to-do: " }, function(input)
		if input then
			input = input:gsub("\n", " ")
			if input ~= "" then
				-- If user has priority config, ask for priorities
				if config.options.priorities and #config.options.priorities > 0 then
					local priorities = config.options.priorities
					local priority_options = {}
					local selected_priorities = {}

					for i, priority in ipairs(priorities) do
						priority_options[i] = string.format("[ ] %s", priority.name)
					end

					local select_buf = vim.api.nvim_create_buf(false, true)
					local ui = vim.api.nvim_list_uis()[1]
					local width = 40
					local height = #priority_options + 2
					local row = math.floor((ui.height - height) / 2)
					local col = math.floor((ui.width - width) / 2)

					local keymaps = {
						config.options.keymaps.toggle_priority,
						"<CR>",
						"q",
						"<Esc>",
					}

					local select_win = vim.api.nvim_open_win(select_buf, true, {
						relative = "editor",
						width = width,
						height = height,
						row = row,
						col = col,
						style = "minimal",
						border = "rounded",
						title = " Select Priorities ",
						title_pos = "center",
						footer = string.format(
							" %s: toggle | <Enter>: confirm ",
							config.options.keymaps.toggle_priority
						),
						footer_pos = "center",
					})

					vim.api.nvim_buf_set_lines(select_buf, 0, -1, false, priority_options)
					vim.api.nvim_buf_set_option(select_buf, "modifiable", false)

					-- Toggle selection
					vim.keymap.set("n", config.options.keymaps.toggle_priority, function()
						if not (select_win and vim.api.nvim_win_is_valid(select_win)) then
							return
						end

						local cursor = vim.api.nvim_win_get_cursor(select_win)
						local line_num = cursor[1]
						local line_text = vim.api.nvim_buf_get_lines(select_buf, line_num - 1, line_num, false)[1]

						vim.api.nvim_buf_set_option(select_buf, "modifiable", true)
						if line_text:match("^%[%s%]") then
							local new_line = line_text:gsub("^%[%s%]", "[x]")
							selected_priorities[line_num] = true
							vim.api.nvim_buf_set_lines(select_buf, line_num - 1, line_num, false, { new_line })
						else
							local new_line = line_text:gsub("^%[x%]", "[ ]")
							selected_priorities[line_num] = nil
							vim.api.nvim_buf_set_lines(select_buf, line_num - 1, line_num, false, { new_line })
						end
						vim.api.nvim_buf_set_option(select_buf, "modifiable", false)
					end, { buffer = select_buf, nowait = true })

					-- Confirm selection
					vim.keymap.set("n", "<CR>", function()
						if not (select_win and vim.api.nvim_win_is_valid(select_win)) then
							return
						end

						local selected_priority_names = {}
						for idx, _ in pairs(selected_priorities) do
							local prio = priorities[idx]
							if prio then
								table.insert(selected_priority_names, prio.name)
							end
						end

						cleanup_priority_selection(select_buf, select_win, keymaps)

						local final_priorities = #selected_priority_names > 0 and selected_priority_names or nil
						state.add_todo(input, final_priorities)
						if on_render then
							on_render()
						end
					end, { buffer = select_buf, nowait = true })

					-- Close selection
					local function close_window()
						cleanup_priority_selection(select_buf, select_win, keymaps)
					end

					vim.keymap.set("n", "q", close_window, { buffer = select_buf, nowait = true })
					vim.keymap.set("n", "<Esc>", close_window, { buffer = select_buf, nowait = true })

					vim.api.nvim_create_autocmd("BufLeave", {
						buffer = select_buf,
						callback = function()
							cleanup_priority_selection(select_buf, select_win, keymaps)
							return true
						end,
						once = true,
					})
				else
					-- No priorities configured, just add the todo
					state.add_todo(input)
					if on_render then
						on_render()
					end
				end
			end
		end
	end)
end

function M.toggle_todo(win_id, on_render)
	if not win_id or not vim.api.nvim_win_is_valid(win_id) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(win_id)
	local todo_index = cursor[1] - 1

	local done_icon = config.options.formatting.done.icon
	local pending_icon = config.options.formatting.pending.icon
	local in_progress_icon = config.options.formatting.in_progress.icon

	local buf_id = vim.api.nvim_win_get_buf(win_id)
	local line_content = vim.api.nvim_buf_get_lines(buf_id, todo_index, todo_index + 1, false)[1]

	if line_content and line_content:match("^%s+[" .. done_icon .. pending_icon .. in_progress_icon .. "]") then
		if state.active_filter then
			local visible_index = 0
			for i, todo in ipairs(state.todos) do
				if todo.text:match("#" .. state.active_filter) then
					visible_index = visible_index + 1
					if visible_index == todo_index - 2 then
						state.toggle_todo(i)
						break
					end
				end
			end
		else
			state.toggle_todo(todo_index)
		end

		if on_render then
			on_render()
		end
	end
end

function M.delete_todo(win_id, on_render)
	if not win_id or not vim.api.nvim_win_is_valid(win_id) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(win_id)
	local todo_index = cursor[1] - 1

	local done_icon = config.options.formatting.done.icon
	local pending_icon = config.options.formatting.pending.icon
	local in_progress_icon = config.options.formatting.in_progress.icon

	local buf_id = vim.api.nvim_win_get_buf(win_id)
	local line_content = vim.api.nvim_buf_get_lines(buf_id, todo_index, todo_index + 1, false)[1]

	if line_content and line_content:match("^%s+[" .. done_icon .. pending_icon .. in_progress_icon .. "]") then
		if state.active_filter then
			local visible_index = 0
			for i, todo in ipairs(state.todos) do
				if todo.text:match("#" .. state.active_filter) then
					visible_index = visible_index + 1
					if visible_index == todo_index - 2 then
						todo_index = i
						break
					end
				end
			end
		end

		-- The original code calls state.delete_todo_with_confirmation
		state.delete_todo_with_confirmation(todo_index, win_id, calendar, function()
			if on_render then
				on_render()
			end
		end)
	end
end

function M.delete_completed(on_render)
	state.delete_completed()
	if on_render then
		on_render()
	end
end

function M.remove_duplicates(on_render)
	local dups = state.remove_duplicates()
	vim.notify("Removed " .. dups .. " duplicates.", vim.log.levels.INFO)
	if on_render then
		on_render()
	end
end

-- Edits an existing todo
function M.edit_todo(win_id, on_render)
	local cursor = vim.api.nvim_win_get_cursor(win_id)
	local todo_index = cursor[1] - 1

	local buf_id = vim.api.nvim_win_get_buf(win_id)
	local line_content = vim.api.nvim_buf_get_lines(buf_id, todo_index, todo_index + 1, false)[1]

	local done_icon = config.options.formatting.done.icon
	local pending_icon = config.options.formatting.pending.icon
	local in_progress_icon = config.options.formatting.in_progress.icon

	if line_content:match("^%s+[" .. done_icon .. pending_icon .. in_progress_icon .. "]") then
		if state.active_filter then
			local visible_index = 0
			for i, todo in ipairs(state.todos) do
				if todo.text:match("#" .. state.active_filter) then
					visible_index = visible_index + 1
					if visible_index == todo_index - 2 then
						todo_index = i
						break
					end
				end
			end
		end

		vim.ui.input({ zindex = 300, prompt = "Edit to-do: ", default = state.todos[todo_index].text }, function(input)
			if input and input ~= "" then
				state.todos[todo_index].text = input
				state.save_to_disk()
				if on_render then
					on_render()
				end
			end
		end)
	end
end

-- Edits the priorities of an existing todo
function M.edit_priorities(win_id, on_render)
	local cursor = vim.api.nvim_win_get_cursor(win_id)
	local todo_index = cursor[1] - 1

	local buf_id = vim.api.nvim_win_get_buf(win_id)
	local line_content = vim.api.nvim_buf_get_lines(buf_id, todo_index, todo_index + 1, false)[1]

	local done_icon = config.options.formatting.done.icon
	local pending_icon = config.options.formatting.pending.icon
	local in_progress_icon = config.options.formatting.in_progress.icon

	if line_content:match("^%s+[" .. done_icon .. pending_icon .. in_progress_icon .. "]") then
		if state.active_filter then
			local visible_index = 0
			for i, todo in ipairs(state.todos) do
				if todo.text:match("#" .. state.active_filter) then
					visible_index = visible_index + 1
					if visible_index == todo_index - 2 then
						todo_index = i
						break
					end
				end
			end
		end

		if config.options.priorities and #config.options.priorities > 0 then
			local priorities = config.options.priorities
			local priority_options = {}
			local selected_priorities = {}
			local current_todo = state.todos[todo_index]

			-- Pre-select existing
			for i, priority in ipairs(priorities) do
				local is_selected = false
				if current_todo.priorities then
					for _, existing_priority in ipairs(current_todo.priorities) do
						if existing_priority == priority.name then
							is_selected = true
							selected_priorities[i] = true
							break
						end
					end
				end
				priority_options[i] = string.format("[%s] %s", is_selected and "x" or " ", priority.name)
			end

			local select_buf = vim.api.nvim_create_buf(false, true)
			local ui = vim.api.nvim_list_uis()[1]
			local width = 40
			local height = #priority_options + 2
			local row = math.floor((ui.height - height) / 2)
			local col = math.floor((ui.width - width) / 2)

			local keymaps = {
				config.options.keymaps.toggle_priority,
				"<CR>",
				"q",
				"<Esc>",
			}

			local select_win = vim.api.nvim_open_win(select_buf, true, {
				relative = "editor",
				width = width,
				height = height,
				row = row,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " Edit Priorities ",
				title_pos = "center",
				footer = string.format(" %s: toggle | <Enter>: confirm ", config.options.keymaps.toggle_priority),
				footer_pos = "center",
			})

			vim.api.nvim_buf_set_lines(select_buf, 0, -1, false, priority_options)
			vim.api.nvim_buf_set_option(select_buf, "modifiable", false)

			vim.keymap.set("n", config.options.keymaps.toggle_priority, function()
				if not (select_win and vim.api.nvim_win_is_valid(select_win)) then
					return
				end
				local c = vim.api.nvim_win_get_cursor(select_win)
				local line_num = c[1]
				local line_text = vim.api.nvim_buf_get_lines(select_buf, line_num - 1, line_num, false)[1]

				vim.api.nvim_buf_set_option(select_buf, "modifiable", true)
				if line_text:match("^%[%s%]") then
					local new_line = line_text:gsub("^%[%s%]", "[x]")
					selected_priorities[line_num] = true
					vim.api.nvim_buf_set_lines(select_buf, line_num - 1, line_num, false, { new_line })
				else
					local new_line = line_text:gsub("^%[x%]", "[ ]")
					selected_priorities[line_num] = nil
					vim.api.nvim_buf_set_lines(select_buf, line_num - 1, line_num, false, { new_line })
				end
				vim.api.nvim_buf_set_option(select_buf, "modifiable", false)
			end, { buffer = select_buf, nowait = true })

			vim.keymap.set("n", "<CR>", function()
				if not (select_win and vim.api.nvim_win_is_valid(select_win)) then
					return
				end

				local selected_priority_names = {}
				for idx, _ in pairs(selected_priorities) do
					local prio = priorities[idx]
					if prio then
						table.insert(selected_priority_names, prio.name)
					end
				end

				cleanup_priority_selection(select_buf, select_win, keymaps)

				state.todos[todo_index].priorities = #selected_priority_names > 0 and selected_priority_names or nil
				state.save_to_disk()
				if on_render then
					on_render()
				end
			end, { buffer = select_buf, nowait = true })

			local function close_window()
				cleanup_priority_selection(select_buf, select_win, keymaps)
			end

			vim.keymap.set("n", "q", close_window, { buffer = select_buf, nowait = true })
			vim.keymap.set("n", "<Esc>", close_window, { buffer = select_buf, nowait = true })

			vim.api.nvim_create_autocmd("BufLeave", {
				buffer = select_buf,
				callback = function()
					cleanup_priority_selection(select_buf, select_win, keymaps)
					return true
				end,
				once = true,
			})
		end
	end
end

-- Add time estimation
function M.add_time_estimation(win_id, on_render)
	local current_line = vim.api.nvim_win_get_cursor(win_id)[1]
	local todo_index = current_line - (state.active_filter and 3 or 1)

	vim.ui.input({
		prompt = "Estimated completion time (e.g., 15m, 2h, 1d, 0.5w): ",
		default = "",
	}, function(input)
		if input and input ~= "" then
			local hours, err = M.parse_time_estimation(input)
			if hours then
				state.todos[todo_index].estimated_hours = hours
				state.save_to_disk()
				vim.notify("Time estimation added successfully", vim.log.levels.INFO)
			else
				vim.notify("Error adding time estimation: " .. (err or "Unknown error"), vim.log.levels.ERROR)
			end
			if on_render then
				on_render()
			end
		end
	end)
end

-- Remove time estimation
function M.remove_time_estimation(win_id, on_render)
	local current_line = vim.api.nvim_win_get_cursor(win_id)[1]
	local todo_index = current_line - (state.active_filter and 3 or 1)

	if state.todos[todo_index] then
		state.todos[todo_index].estimated_hours = nil
		state.save_to_disk()
		vim.notify("Time estimation removed successfully", vim.log.levels.INFO)
		if on_render then
			on_render()
		end
	else
		vim.notify("Error removing time estimation", vim.log.levels.ERROR)
	end
end

-- Add a due date
function M.add_due_date(win_id, on_render)
	local current_line = vim.api.nvim_win_get_cursor(win_id)[1]
	local todo_index = current_line - (state.active_filter and 3 or 1)

	calendar.create(function(date_str)
		if date_str and date_str ~= "" then
			local success, err = state.add_due_date(todo_index, date_str)
			if success then
				vim.notify("Due date added successfully", vim.log.levels.INFO)
			else
				vim.notify("Error adding due date: " .. (err or "Unknown error"), vim.log.levels.ERROR)
			end
			if on_render then
				on_render()
			end
		end
	end, { language = "en" })
end

-- Remove a due date
function M.remove_due_date(win_id, on_render)
	local current_line = vim.api.nvim_win_get_cursor(win_id)[1]
	local todo_index = current_line - (state.active_filter and 3 or 1)

	local success = state.remove_due_date(todo_index)
	if success then
		vim.notify("Due date removed successfully", vim.log.levels.INFO)
	else
		vim.notify("Error removing due date", vim.log.levels.ERROR)
	end

	if on_render then
		on_render()
	end
end

-- Reorder todo items
function M.reorder_todo(win_id, on_render)
	if not win_id or not vim.api.nvim_win_is_valid(win_id) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(win_id)
	local line_num = cursor[1]
	
	-- Get the current todo index
	local todo_index = line_num - (state.active_filter and 3 or 1)
	if todo_index < 1 or todo_index > #state.todos then
		return
	end

	-- Highlight the current line
	local buf_id = vim.api.nvim_win_get_buf(win_id)
	local ns_id = vim.api.nvim_create_namespace("doit_reorder")
	vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
	vim.api.nvim_buf_add_highlight(buf_id, ns_id, "IncSearch", line_num - 1, 0, -1)

	-- Create a notification
	vim.notify(
		"Reordering mode: Press j/k to move todo up/down, press r to save and exit",
		vim.log.levels.INFO
	)

	-- Temporarily save the current keymaps
	local old_j_keymap = vim.fn.maparg("j", "n", false, true)
	local old_k_keymap = vim.fn.maparg("k", "n", false, true)
	local old_r_keymap = vim.fn.maparg("r", "n", false, true)

	-- Define the function to exit reordering mode and restore keymaps
	local function exit_reorder_mode()
		-- Clear highlights
		vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)

		-- Restore original key mappings if they existed
		if old_j_keymap and not vim.tbl_isempty(old_j_keymap) then
			vim.keymap.set("n", "j", old_j_keymap.rhs, { buffer = buf_id, noremap = old_j_keymap.noremap, silent = old_j_keymap.silent })
		else
			vim.keymap.del("n", "j", { buffer = buf_id })
		end

		if old_k_keymap and not vim.tbl_isempty(old_k_keymap) then
			vim.keymap.set("n", "k", old_k_keymap.rhs, { buffer = buf_id, noremap = old_k_keymap.noremap, silent = old_k_keymap.silent })
		else
			vim.keymap.del("n", "k", { buffer = buf_id })
		end

		if old_r_keymap and not vim.tbl_isempty(old_r_keymap) then
			vim.keymap.set("n", "r", old_r_keymap.rhs, { buffer = buf_id, noremap = old_r_keymap.noremap, silent = old_r_keymap.silent })
		else
			vim.keymap.del("n", "r", { buffer = buf_id })
		end

		-- Notify user that reorder mode is exited
		vim.notify("Reordering mode exited and saved", vim.log.levels.INFO)
	end

	-- Function to update the order indices
	local function update_order_indices()
		-- Reset all todos' order_index property to match their position in the array
		for i, todo in ipairs(state.todos) do
			todo.order_index = i
		end
		state.save_to_disk()
	end

	-- Move the todo down in the list
	vim.keymap.set("n", config.options.keymaps.move_todo_down, function()
		local current_index = line_num - (state.active_filter and 3 or 1)

		-- Determine if we're working with filtered or unfiltered todos
		local valid_todos = state.active_filter 
			and vim.tbl_filter(function(t) return t.text:match("#" .. state.active_filter) end, state.todos)
			or state.todos

		if current_index >= #valid_todos then
			-- Already at the bottom
			return
		end

		-- Get the real index in state.todos
		local real_index
		if state.active_filter then
			local visible_count = 0
			for i, todo in ipairs(state.todos) do
				if todo.text:match("#" .. state.active_filter) then
					visible_count = visible_count + 1
					if visible_count == current_index then
						real_index = i
						break
					end
				end
			end
		else
			real_index = current_index
		end

		-- Find the next todo in state.todos (might need to skip some if filtering)
		local next_index
		if state.active_filter then
			local found_current = false
			for i, todo in ipairs(state.todos) do
				if i == real_index then
					found_current = true
				elseif found_current and todo.text:match("#" .. state.active_filter) then
					next_index = i
					break
				end
			end
		else
			next_index = real_index + 1
		end

		if real_index and next_index then
			-- Swap order indices
			local tmp_order = state.todos[real_index].order_index
			state.todos[real_index].order_index = state.todos[next_index].order_index
			state.todos[next_index].order_index = tmp_order

			-- Resort based on new order indices
			state.sort_todos()
			
			-- Move the cursor and highlight
			if on_render then
				on_render()
			end
			
			-- Update cursor position to follow the moved todo
			local new_line_num
			if state.active_filter then
				-- Find the new position of the todo in the filtered view
				local visible_count = 0
				for i, todo in ipairs(state.todos) do
					if todo.text:match("#" .. state.active_filter) then
						visible_count = visible_count + 1
						if i == next_index then
							new_line_num = visible_count + (state.active_filter and 3 or 1)
							break
						end
					end
				end
			else
				-- In unfiltered view, the new position is simply the next_index
				new_line_num = next_index + 1
			end
			
			if new_line_num then
				vim.api.nvim_win_set_cursor(win_id, {new_line_num, 0})
				line_num = new_line_num
				vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
				vim.api.nvim_buf_add_highlight(buf_id, ns_id, "IncSearch", new_line_num - 1, 0, -1)
			end
		end
	end, { buffer = buf_id, nowait = true })

	-- Move the todo up in the list
	vim.keymap.set("n", config.options.keymaps.move_todo_up, function()
		local current_index = line_num - (state.active_filter and 3 or 1)
		if current_index <= 1 then
			-- Already at the top
			return
		end

		-- Determine if we're working with filtered or unfiltered todos
		local valid_todos = state.active_filter 
			and vim.tbl_filter(function(t) return t.text:match("#" .. state.active_filter) end, state.todos)
			or state.todos

		-- Get the real index in state.todos
		local real_index
		if state.active_filter then
			local visible_count = 0
			for i, todo in ipairs(state.todos) do
				if todo.text:match("#" .. state.active_filter) then
					visible_count = visible_count + 1
					if visible_count == current_index then
						real_index = i
						break
					end
				end
			end
		else
			real_index = current_index
		end

		-- Find the previous todo in state.todos (might need to skip some if filtering)
		local prev_index
		if state.active_filter then
			for i = real_index - 1, 1, -1 do
				if state.todos[i].text:match("#" .. state.active_filter) then
					prev_index = i
					break
				end
			end
		else
			prev_index = real_index - 1
		end

		if real_index and prev_index then
			-- Swap order indices
			local tmp_order = state.todos[real_index].order_index
			state.todos[real_index].order_index = state.todos[prev_index].order_index
			state.todos[prev_index].order_index = tmp_order

			-- Resort based on new order indices
			state.sort_todos()
			
			-- Move the cursor and highlight
			if on_render then
				on_render()
			end
			
			-- Update cursor position to follow the moved todo
			local new_line_num
			if state.active_filter then
				-- Find the new position of the todo in the filtered view
				local visible_count = 0
				for i, todo in ipairs(state.todos) do
					if todo.text:match("#" .. state.active_filter) then
						visible_count = visible_count + 1
						if i == prev_index then
							new_line_num = visible_count + (state.active_filter and 3 or 1)
							break
						end
					end
				end
			else
				-- In unfiltered view, the new position is simply the prev_index
				new_line_num = prev_index + 1
			end
			
			if new_line_num then
				vim.api.nvim_win_set_cursor(win_id, {new_line_num, 0})
				line_num = new_line_num
				vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
				vim.api.nvim_buf_add_highlight(buf_id, ns_id, "IncSearch", new_line_num - 1, 0, -1)
			end
		end
	end, { buffer = buf_id, nowait = true })

	-- Exit reordering mode
	vim.keymap.set("n", config.options.keymaps.reorder_todo, function()
		-- Update all order_index values before exiting
		update_order_indices()
		exit_reorder_mode()
		if on_render then
			on_render()
		end
	end, { buffer = buf_id, nowait = true })

	-- Also allow escape to exit reordering mode
	vim.keymap.set("n", "<Esc>", function()
		update_order_indices()
		exit_reorder_mode()
		if on_render then
			on_render()
		end
	end, { buffer = buf_id, nowait = true })
end

return M
