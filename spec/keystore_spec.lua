local helper = require("helper")

describe("KeyStore", function()
    -- These are not real keys or sessions, only shaped like them.
    local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
    local OTHER_KEY = "ZyXwVuT9sRqPoNmLkJhGfEdCbA65432"
    local SESSION = "eyJhIjoiYWJjZGVmZyIsImlhdCI6MX0.c2lnbmF0dXJlLXZhbHVl_x-y"
    local GL, PK = "https://annas-archive.gl", "https://annas-archive.pk"
    local NOW = 1794440000

    local data_dir, KeyStore, Settings, LogUtil

    local function load()
        KeyStore = require("fetchanna.api.keystore")
        Settings = require("fetchanna.settings.settings")
        LogUtil = require("fetchanna.util.logutil")
    end

    -- Simulates a KOReader restart: FetchAnna reloads with what was saved.
    local function restart()
        for name in pairs(package.loaded) do
            if name:find("^fetchanna%.") then
                package.loaded[name] = nil
            end
        end
        load()
    end

    local function keyFile()
        return data_dir .. "/settings/fetchanna_key.txt"
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        load()
    end)

    after_each(helper.cleanup)

    describe("by default", function()
        it("keeps the key only until KOReader restarts", function()
            assert.is_true(KeyStore.setKey(KEY))
            assert.are.equal(KEY, KeyStore.getKey())
            assert.is_false(helper.exists(keyFile()))
            assert.is_false(KeyStore.isRemembered())

            restart()
            assert.is_nil(KeyStore.getKey())
        end)

        it("never puts the key in the settings", function()
            KeyStore.setKey(KEY)
            KeyStore.setRemembered(true)
            for path, settings in pairs(helper.state.settings_files) do
                for name, value in pairs(settings) do
                    assert.is_nil(tostring(value):find(KEY, 1, true), path .. ": " .. name)
                end
            end
        end)
    end)

    describe("remembered on the device", function()
        before_each(function()
            KeyStore.setKey(KEY)
            assert.is_true(KeyStore.setRemembered(true))
        end)

        it("keeps the key, its sessions and what's known of the account when KOReader restarts", function()
            KeyStore.setSession(GL, SESSION, NOW + 90 * 86400)
            KeyStore.setInfo({ verified_at = NOW, tier = 3, failure = "challenge" })

            restart()
            assert.are.equal(KEY, KeyStore.getKey())
            assert.are.equal(SESSION, KeyStore.getSession(GL))
            assert.are.same({ verified_at = NOW, tier = 3, failure = "challenge" }, KeyStore.getInfo())
            -- Never logged.
            assert.are.equal("[redacted] [redacted]", LogUtil.redact(KEY .. " " .. SESSION))
        end)

        it("says in the file what it is, and that it isn't encrypted", function()
            local content = helper.readFile(keyFile())
            assert.matches("^# FetchAnna: your Anna's Archive secret key", content)
            assert.matches("This file isn't encrypted", content)
            assert.matches("\nkey " .. KEY .. "\n", content)
        end)

        it("leaves out of the file what isn't as it was written", function()
            helper.writeFile(
                keyFile(),
                table.concat({
                    "key not a key!",
                    "key short",
                    "session http://annas-archive.gl " .. SESSION .. " 0 0",
                    "session " .. PK .. " bad;value 0 0",
                    "info tier three",
                    "info admin 1",
                    "key " .. OTHER_KEY,
                }, "\n")
            )
            restart()
            assert.are.equal(OTHER_KEY, KeyStore.getKey())
            assert.are.same({}, KeyStore.sessions())
            assert.are.same({}, KeyStore.getInfo())
        end)

        it("doesn't keep sessions without a key", function()
            helper.writeFile(keyFile(), "session " .. GL .. " " .. SESSION .. " 0 0\n")
            restart()
            assert.is_nil(KeyStore.getKey())
            assert.is_nil(KeyStore.getSession(GL))
        end)

        it("forgets it all, removing the file", function()
            KeyStore.setSession(GL, SESSION, NOW + 3600)
            assert.is_true(KeyStore.forget())
            assert.is_nil(KeyStore.getKey())
            assert.is_nil(KeyStore.getSession(GL))
            assert.is_false(helper.exists(keyFile()))
            restart()
            assert.is_nil(KeyStore.getKey())
        end)

        it("removes the file once it's no longer to be remembered, keeping the key until KOReader restarts", function()
            assert.is_true(KeyStore.setRemembered(false))
            assert.is_false(helper.exists(keyFile()))
            assert.are.equal(KEY, KeyStore.getKey())
            restart()
            assert.is_nil(KeyStore.getKey())
        end)

        -- When the setting was turned off but the file couldn't be removed.
        it("removes a file left from when it was remembered", function()
            Settings:setRememberKey(false)
            restart()
            assert.is_nil(KeyStore.getKey())
            assert.is_false(helper.exists(keyFile()))
        end)
    end)

    -- Runs in /tmp, where storage has owners. The repository's may not.
    it("has the file be read by its owner only", function()
        local tmp_data = os.tmpname()
        os.remove(tmp_data)
        helper.run("mkdir -p " .. helper.quote(tmp_data .. "/settings"))
        data_dir = tmp_data
        helper.state.data_dir = tmp_data
        restart()
        KeyStore.setKey(KEY)
        KeyStore.setRemembered(true)
        local ok = pcall(helper.run, 'test "$(stat -c %a ' .. helper.quote(keyFile()) .. ')" = 600')
        helper.run("rm -rf " .. helper.quote(tmp_data))
        assert.is_true(ok)
    end)

    describe("sessions", function()
        before_each(function()
            KeyStore.setKey(KEY)
        end)

        it("are kept for each site separately, without their values being listed", function()
            KeyStore.setSession(GL, SESSION, NOW + 3600)
            assert.are.equal(SESSION, KeyStore.getSession(GL))
            assert.is_nil(KeyStore.getSession(PK))
            assert.are.same({ { origin = GL, expires_at = NOW + 3600, created_at = NOW } }, KeyStore.sessions())
        end)

        it("are forgotten once they expire", function()
            KeyStore.setSession(GL, SESSION, NOW + 60)
            helper.state.time = NOW + 60
            assert.is_nil(KeyStore.getSession(GL))
            assert.are.same({}, KeyStore.sessions())
        end)

        it("are forgotten, with what's known of the account, when the key changes", function()
            KeyStore.setSession(GL, SESSION, NOW + 3600)
            KeyStore.setInfo({ tier = 2 })
            KeyStore.setKey(KEY)
            assert.are.equal(SESSION, KeyStore.getSession(GL))
            KeyStore.setKey(OTHER_KEY)
            assert.is_nil(KeyStore.getSession(GL))
            assert.are.same({}, KeyStore.getInfo())
        end)

        it("can be dropped one site at a time, or all at once", function()
            KeyStore.setSession(GL, SESSION, NOW + 3600)
            KeyStore.setSession(PK, SESSION .. "2", NOW + 3600)
            KeyStore.dropSession(GL)
            assert.is_nil(KeyStore.getSession(GL))
            assert.is_not_nil(KeyStore.getSession(PK))
            KeyStore.dropSession()
            assert.are.same({}, KeyStore.sessions())
        end)

        it("are only ever an origin's, and as Anna's Archive's are", function()
            assert.has_error(function()
                KeyStore.setSession("https://annas-archive.gl/account/", SESSION, NOW)
            end)
            assert.has_error(function()
                KeyStore.setSession(GL, "a=b; Path=/", NOW)
            end)
        end)
    end)

    it("only takes keys as Anna's Archive's are", function()
        assert.is_true(KeyStore.isValidKey(KEY))
        for _, key in ipairs({ "short", KEY .. " ", "key with spaces in it, long enough", KEY .. "&x=1", 42, nil }) do
            assert.is_false(KeyStore.isValidKey(key), tostring(key))
        end
        assert.has_error(function()
            KeyStore.setKey("not a key")
        end)
    end)

    it("notes only what it knows about an account, forgetting what it's told to", function()
        KeyStore.setKey(KEY)
        KeyStore.setInfo({ tier = 3, downloads_left = "many", admin = true, verified_at = NOW })
        assert.are.same({ tier = 3, verified_at = NOW }, KeyStore.getInfo())
        KeyStore.setInfo({ tier = false })
        assert.are.same({ verified_at = NOW }, KeyStore.getInfo())
    end)
end)
