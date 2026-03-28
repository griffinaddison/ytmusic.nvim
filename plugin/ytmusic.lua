if vim.g.loaded_ytmusic then
  return
end
vim.g.loaded_ytmusic = true

vim.api.nvim_create_user_command("YTMusic", function()
  require("ytmusic").open()
end, { desc = "Open YouTube Music browser" })

vim.api.nvim_create_user_command("YTSearch", function(opts)
  require("ytmusic").search(opts.args)
end, { nargs = 1, desc = "Search YouTube Music" })
