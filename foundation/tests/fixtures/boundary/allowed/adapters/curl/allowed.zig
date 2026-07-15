const c = @cImport({
    @cInclude("curl/curl.h");
});

test "adapter vendor import is allowed" {
    _ = c;
}
