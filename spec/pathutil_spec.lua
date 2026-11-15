local helper = require("helper")

describe("PathUtil", function()
    local data_dir

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
    end)

    after_each(helper.cleanup)

    describe("getPluginPath", function()
        it("returns the directory the plugin was loaded from", function()
            local PathUtil = require("fetchanna.util.pathutil")
            assert.are.equal("fetchanna.koplugin", PathUtil.getPluginPath())
        end)

        it("finds plugins installed in koreader's data dir (android)", function()
            -- KOReader registers "<data dir>/plugins/" as an extra plugin path, hence the double slash.
            local plugin_path = helper.abs(data_dir) .. "/plugins//fetchanna.koplugin"
            local PathUtil = helper.loadPluginFileFrom(plugin_path, "fetchanna/util/pathutil.lua")
            assert.are.equal(plugin_path, PathUtil.getPluginPath())
        end)

        it("finds plugins installed under a different folder name", function()
            local plugin_path = data_dir .. "/plugins/FetchAnna-main.koplugin"
            local PathUtil = helper.loadPluginFileFrom(plugin_path, "fetchanna/util/pathutil.lua")
            assert.are.equal(plugin_path, PathUtil.getPluginPath())
        end)

        it("falls back to koreader's data dir when the load location is unknown", function()
            local source = helper.readFile("fetchanna.koplugin/fetchanna/util/pathutil.lua")
            local PathUtil = (loadstring or load)(source, "=pathutil")()
            assert.are.equal(data_dir .. "/plugins/fetchanna.koplugin", PathUtil.getPluginPath())
        end)
    end)

    describe("getTmpPath", function()
        it("creates a fetchanna directory inside koreader's cache dir", function()
            local PathUtil = require("fetchanna.util.pathutil")
            local tmp_path = PathUtil.getTmpPath()
            assert.are.equal(data_dir .. "/cache/fetchanna", tmp_path)
            assert.is_true(helper.isDir(tmp_path))
        end)

        it("reuses the directory when it already exists", function()
            local PathUtil = require("fetchanna.util.pathutil")
            helper.writeFile(PathUtil.getTmpPath() .. "/partial.zip", "data")
            assert.are.equal(data_dir .. "/cache/fetchanna", PathUtil.getTmpPath())
            assert.is_true(helper.exists(data_dir .. "/cache/fetchanna/partial.zip"))
        end)
    end)
end)
