//! Narrow source-kind capabilities over the shared fetch service.

const FileCache = @import("store").FileCache;
const types = @import("types.zig");

pub fn UrlFetcher(comptime Service: type) type {
    return struct {
        service: *Service,

        pub fn fetch(self: @This(), files: *FileCache, spec: types.UrlSpec, reporter: ?types.Reporter) !types.UrlResult {
            return self.service.fetchUrl(files, spec, reporter);
        }

        pub fn fetchTarball(self: @This(), files: *FileCache, spec: types.TarballSpec, reporter: ?types.Reporter) !types.TarballResult {
            return self.service.fetchTarball(files, spec, reporter);
        }
    };
}

pub fn GitFetcher(comptime Service: type) type {
    return struct {
        service: *Service,

        pub fn fetch(self: @This(), files: *FileCache, spec: types.GitSpec, reporter: ?types.Reporter) !types.GitResult {
            return self.service.fetchGit(files, spec, reporter);
        }
    };
}

pub fn MercurialFetcher(comptime Service: type) type {
    return struct {
        service: *Service,

        pub fn fetch(self: @This(), files: *FileCache, spec: types.MercurialSpec, reporter: ?types.Reporter) !types.MercurialResult {
            return self.service.fetchMercurial(files, spec, reporter);
        }
    };
}
