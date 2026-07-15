const c = @cImport({
    @cInclude("curl/curl.h");
});

test "non adapter vendor import is forbidden" {
    _ = c;
}
