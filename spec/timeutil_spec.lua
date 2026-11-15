local helper = require("helper")

describe("TimeUtil", function()
    local TimeUtil

    before_each(function()
        helper.reset()
        TimeUtil = require("fetchanna.util.timeutil")
    end)

    it("works out times in UTC whatever the device's time zone", function()
        assert.are.equal(0, TimeUtil.utcTime(1970, 1, 1, 0, 0, 0))
        assert.are.equal(951782400, TimeUtil.utcTime(2000, 2, 29, 0, 0, 0))
        assert.are.equal(1794438778, TimeUtil.utcTime(2026, 11, 11, 23, 12, 58))
    end)

    it("reads dates as HTTP writes them", function()
        -- The time DDoS-Guard's cookie, sent with this date, said it was.
        assert.are.equal(1794438954, TimeUtil.parseHttpDate("Wed, 11 Nov 2026 23:15:54 GMT"))
        assert.are.equal(0, TimeUtil.parseHttpDate("Thu, 1 Jan 1970 00:00:00 GMT"))
        local not_dates = { "11 Nov 2026", "Wed, 11 Foo 2026 23:15:54 GMT", "Wed, 11 Nov 2026 23:15:54 PST", 42 }
        for _, text in ipairs(not_dates) do
            assert.is_nil(TimeUtil.parseHttpDate(text), tostring(text))
        end
    end)

    describe("parseRetryAfter", function()
        it("reads seconds", function()
            assert.are.equal(120, TimeUtil.parseRetryAfter("120", 0))
            assert.are.equal(0, TimeUtil.parseRetryAfter(" 0 ", 0))
        end)

        it("reads a date, as how long until then", function()
            assert.are.equal(54, TimeUtil.parseRetryAfter("Wed, 11 Nov 2026 23:15:54 GMT", 1794438900))
            assert.are.equal(0, TimeUtil.parseRetryAfter("Wed, 11 Nov 2026 23:15:54 GMT", 1794439000))
        end)

        it("is nil when it doesn't say", function()
            assert.is_nil(TimeUtil.parseRetryAfter("soon", 0))
            assert.is_nil(TimeUtil.parseRetryAfter("-5", 0))
            assert.is_nil(TimeUtil.parseRetryAfter(nil, 0))
        end)
    end)
end)
