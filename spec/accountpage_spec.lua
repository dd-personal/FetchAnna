local helper = require("helper")

describe("AccountPage", function()
    -- These are not real keys or sessions, only shaped like them.
    local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
    local SESSION = "eyJhIjoiYWJjZGVmZyIsImlhdCI6MX0.c2lnbmF0dXJlLXZhbHVl_x-y"
    local GD = "https://annas-archive.gd"
    local NOW = 1794440000
    local invalid_key_answer = helper.readFile("spec/data/annas/fast-download-401-invalid-key.json")
    local not_found_answer = helper
        .readFile("spec/data/annas/fast-download-400-invalid-md5.json")
        :gsub('"Invalid md5"', '"Record not found"')
    local challenge = helper.readFile("spec/data/annas/ddos-guard-403-challenge.html")
    -- SYNTHESIZED from Anna's Archive's account page template (see annasaccount_spec.lua).
    local member_page = [[<form onsubmit="window.submitForm(event, '/dyn/account/logout/')"></form>
<div class=" ">Placeholder <a href="/donate?tier=3" class="text-sm hidden">tier</a></div>]]
    local logged_out_page = '<form method="post" action="/account/"><input type="password" name="key"></form>'

    local data_dir, AccountPage, KeyStore, answers

    local function lastMenu()
        for i = #helper.state.shown, 1, -1 do
            local widget = helper.state.shown[i]
            if widget.item_table and not helper.wasClosed(widget) then
                return widget
            end
        end
    end
    local function itemTexts()
        local texts = {}
        for _, item in ipairs(lastMenu().item_table) do
            table.insert(texts, item.text)
        end
        return texts
    end
    local function tap(text)
        for _, item in ipairs(lastMenu().item_table) do
            if item.text:find(text, 1, true) then
                return item.callback()
            end
        end
        error("no menu item containing " .. text)
    end
    local function button(dialog, text)
        for _, row in ipairs(dialog.buttons) do
            for _, b in ipairs(row) do
                if b.text == text then
                    return b
                end
            end
        end
        error("no button " .. text)
    end
    -- Types key into the key dialog and taps a button.
    local function typeKey(key, button_text)
        tap("Key")
        local dialog = helper.lastShown()
        dialog:setInputText(key)
        button(dialog, button_text).callback()
        return dialog
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        helper.stubs.network.connected = true
        answers = {}

        local HttpUtil = require("fetchanna.util.httputil")
        HttpUtil.getBody = function(url, opts)
            opts = opts or {}
            local answer = answers[(opts.form and "POST " or "GET ") .. url:gsub("%?.*$", "")]
            answer = answer or { nil, "failed to connect to server" }
            return answer[1], answer[2], answer[3], answer[4] or {}
        end
        require("fetchanna.util.originpolicy").resolve = function()
            return nil
        end
        KeyStore = require("fetchanna.api.keystore")
        AccountPage = require("fetchanna.ui.accountpage")
        local SettingsPage = require("fetchanna.settings.settingspage")
        AccountPage:show(function(title, items)
            return SettingsPage:newMenu(title, items)
        end)
    end)

    after_each(helper.cleanup)

    it("closes, as KOReader's menus do", function()
        local menu = lastMenu()
        menu:onClose()
        assert.is_true(helper.wasClosed(menu))
    end)

    it("says there's no key, and offers to enter one", function()
        assert.are.equal("Anna's Archive Account", lastMenu().title)
        assert.are.same({
            "Status: No key",
            "Enter Key",
            "Connect",
            "Remember on This Device: ☐",
            "Forget Key and Log Out",
        }, itemTexts())
        assert.is_false(lastMenu().item_table[3].enabled)
        assert.is_false(lastMenu().item_table[5].enabled)
    end)

    describe("entering the key", function()
        it("hides it as it's typed", function()
            tap("Enter Key")
            local dialog = helper.lastShown()
            assert.are.equal("password", dialog.text_type)
            assert.are.equal("Anna's Archive Secret Key", dialog.title)
            assert.is_true(dialog.keyboard_shown)
        end)

        it("saves it, until KOReader restarts", function()
            local dialog = typeKey(" " .. KEY .. " ", "Save")
            assert.is_true(helper.wasClosed(dialog))
            assert.are.equal("Key saved", helper.lastNotification())
            assert.are.equal(KEY, KeyStore.getKey())
            assert.are.equal("Status: Key saved, not checked yet", itemTexts()[1])
            assert.are.equal("Replace Key", itemTexts()[2])
            assert.is_false(helper.exists(KeyStore.path()))
        end)

        it("says what a key is when what's typed isn't one, leaving it to be typed again", function()
            local dialog = typeKey("my password", "Save")
            assert.are.equal(
                "That isn't a secret key: it's letters and digits, at least 20 of them.",
                helper.lastError()
            )
            assert.is_false(helper.wasClosed(dialog))
            assert.is_nil(KeyStore.getKey())
        end)
    end)

    describe("connecting", function()
        it("logs in, saying what the membership allows", function()
            answers["POST " .. GD .. "/account/"] = { "", nil, 302, { ["set-cookie"] = "aa_account_id2=" .. SESSION } }
            answers["GET " .. GD .. "/account/"] = { member_page, nil, 200 }
            typeKey(KEY, "Save and Connect")

            assert.are.equal(
                "Logged in to Anna's Archive on annas-archive.gd.\n"
                    .. "Membership: about 50 fast downloads a day, and 180 searches an hour without a browser check",
                helper.lastShown().text
            )
            assert.are.equal("Status: Logged in", itemTexts()[1])
        end)

        it("says when the key isn't accepted", function()
            answers["POST " .. GD .. "/account/"] = { logged_out_page, nil, 200 }
            typeKey(KEY, "Save and Connect")
            assert.are.equal(
                "Anna's Archive doesn't accept your key. Check it against the one on your account page on "
                    .. "Anna's Archive.",
                helper.lastError()
            )
            assert.are.equal("Status: Key not accepted", itemTexts()[1])
        end)

        it("says when the key is accepted, but FetchAnna couldn't log in", function()
            for _, origin in ipairs({ "https://annas-archive.gl", "https://annas-archive.pk", GD }) do
                answers["POST " .. origin .. "/account/"] = { challenge, nil, 403 }
            end
            answers["GET " .. GD .. "/dyn/api/fast_download.json"] = { not_found_answer, nil, 404 }
            typeKey(KEY, "Save")
            tap("Connect")
            assert.matches(
                "^Anna's Archive accepts your key, but FetchAnna couldn't log in: Anna's Archive asked for a "
                    .. "browser check",
                helper.lastShown().text
            )
            assert.are.equal("Status: Key accepted, not logged in", itemTexts()[1])
        end)

        it("says when Anna's Archive couldn't be asked at all", function()
            typeKey(KEY, "Save")
            tap("Connect")
            assert.are.equal(
                "Anna's Archive didn't answer. Check the Wi-Fi connection, or try again later.",
                helper.lastError()
            )
            assert.are.equal("Status: Key saved, couldn't be checked", itemTexts()[1])
        end)

        it("doesn't show the key or its session anywhere", function()
            answers["POST " .. GD .. "/account/"] = { "", nil, 302, { ["set-cookie"] = "aa_account_id2=" .. SESSION } }
            answers["GET " .. GD .. "/dyn/api/fast_download.json"] = { invalid_key_answer, nil, 401 }
            typeKey(KEY, "Save and Connect")
            tap("Status")
            for _, widget in ipairs(helper.state.shown) do
                -- Only the box it was typed in may show it.
                if widget.text_type ~= "password" then
                    for _, field in ipairs({ "text", "title", "description" }) do
                        local text = tostring(widget[field] or "")
                        assert.is_nil(text:find(KEY, 1, true))
                        assert.is_nil(text:find(SESSION, 1, true))
                    end
                end
            end
            for _, notification in ipairs(helper.state.notifications) do
                assert.is_nil(tostring(notification):find(KEY, 1, true))
            end
        end)
    end)

    it("says all that's known of the account", function()
        answers["POST " .. GD .. "/account/"] = {
            "",
            nil,
            302,
            { ["set-cookie"] = "aa_account_id2=" .. SESSION .. "; Expires=Wed, 10 Feb 2027 23:13:20 GMT" },
        }
        answers["GET " .. GD .. "/account/"] = { member_page, nil, 200 }
        typeKey(KEY, "Save and Connect")
        helper.state.time = NOW + 7200
        tap("Status")
        assert.are.equal(
            table.concat({
                "Logged in",
                "Logged in on annas-archive.gd until " .. os.date("%Y-%m-%d", 1802301200),
                "Membership: about 50 fast downloads a day, and 180 searches an hour without a browser check",
                "Key last accepted 2 hours ago",
                "Your key is kept until KOReader restarts.",
            }, "\n"),
            helper.lastShown().text
        )
    end)

    describe("remembering the key on the device", function()
        before_each(function()
            typeKey(KEY, "Save")
        end)

        it("says where it would be kept, and that it isn't encrypted, before it is", function()
            tap("Remember on This Device")
            local confirm = helper.lastShown()
            assert.matches("fetchanna_key%.txt, unencrypted, so anyone who can read the device's storage", confirm.text)
            assert.is_false(helper.exists(KeyStore.path()))
            confirm.ok_callback()

            assert.is_true(helper.exists(KeyStore.path()))
            assert.are.equal("Your key is remembered on this device", helper.lastNotification())
            assert.are.equal("Remember on This Device: ☑", itemTexts()[4])
        end)

        it("stops, removing the file", function()
            tap("Remember on This Device")
            helper.lastShown().ok_callback()
            tap("Remember on This Device")
            assert.is_false(helper.exists(KeyStore.path()))
            assert.are.equal("Your key is no longer remembered on this device", helper.lastNotification())
            assert.are.equal(KEY, KeyStore.getKey())
        end)
    end)

    it("forgets the key after asking, saying erasing isn't guaranteed", function()
        typeKey(KEY, "Save")
        tap("Forget Key and Log Out")
        local confirm = helper.lastShown()
        assert.matches("removing a file doesn't guarantee that what was in it is erased", confirm.text)
        confirm.ok_callback()
        assert.is_nil(KeyStore.getKey())
        assert.are.equal("Key forgotten", helper.lastNotification())
        assert.are.equal("Status: No key", itemTexts()[1])
    end)
end)
