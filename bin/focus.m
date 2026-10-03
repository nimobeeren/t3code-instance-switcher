// focus — bring one of the T3 Code instances forward.
//
// usage: focus [--helper] [--dry-run]
//   (no flag)  focus one instance, print its name, exit 0
//   --helper   serve focusing over $T3_FOCUS_STATE_DIR/focus.sock and stay warm
//   --dry-run  print the instance that would be focused, activate nothing
//
// The caller (bin/t3-focus) exports T3_FOCUS_STATE_DIR, T3_FOCUS_EXEC and
// T3_FOCUS_INSTANCES, a comma-separated list of name=/path/to/App.app pairs
// taken from config.sh. Which instance goes forward is, in order: the only
// running one; when one of them is the focused application or owns the
// frontmost window, the most recently used one that is not it; otherwise the
// most recently used one, then the last one focused here. Window order comes
// from the window server, so the most recently used instance stays correct
// after clicks, Cmd-Tab and our own focusing, with nothing to record along the
// way. A window that is closed, minimized or on another Space is not in the
// list.
//
// An instance is running when its pid file names a live process of the shared
// T3 Code binary (checked with proc_pidpath, not ps): helper and backend
// processes cannot be activated, which is why the pid recorded at exec time is
// the reliable handle. Activation is by pid via NSRunningApplication; when it
// fails the app bundle is opened instead, which reaches an instance that is
// still starting up.
//
// A press that finds no helper does the work itself and leaves one running;
// later presses ask the helper and skip the window-server connection setup that
// costs a fresh process ~35ms. The helper exits when this binary changes on
// disk, so a rebuilt binary takes over on the next press.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>
#import <libproc.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <spawn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static NSArray<NSString *> *InstanceNames;
static NSArray<NSString *> *AppPaths;
static NSString *StateDir;
static NSString *ExecPath;

static void Die(const char *message) {
  fprintf(stderr, "focus: %s\n", message);
  exit(2);
}

static void LoadConfig(void) {
  NSDictionary *env = [[NSProcessInfo processInfo] environment];
  NSString *stateDir = env[@"T3_FOCUS_STATE_DIR"] ?: @"";
  NSString *execPath = env[@"T3_FOCUS_EXEC"] ?: @"";
  NSString *instances = env[@"T3_FOCUS_INSTANCES"] ?: @"";
  if (stateDir.length == 0 || execPath.length == 0 || instances.length == 0) {
    Die("missing environment; run through bin/t3-focus");
  }

  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSMutableArray<NSString *> *apps = [NSMutableArray array];
  for (NSString *pair in [instances componentsSeparatedByString:@","]) {
    NSRange split = [pair rangeOfString:@"="];
    if (split.location == NSNotFound || split.location == 0 ||
        split.location == pair.length - 1) {
      Die("bad T3_FOCUS_INSTANCES entry, expected name=/path/to/App.app");
    }
    [names addObject:[pair substringToIndex:split.location]];
    [apps addObject:[pair substringFromIndex:split.location + 1]];
  }

  // The apps and the shared binary must exist; the state dir is created below.
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:execPath]) {
    fprintf(stderr, "focus: T3_FOCUS_EXEC does not exist: %s\n", execPath.UTF8String);
    exit(2);
  }
  for (NSString *app in apps) {
    if (![fm fileExistsAtPath:app]) {
      fprintf(stderr, "focus: app does not exist: %s\n", app.UTF8String);
      exit(2);
    }
  }

  InstanceNames = names;
  AppPaths = apps;
  StateDir = stateDir;
  ExecPath = execPath;
  [fm createDirectoryAtPath:StateDir withIntermediateDirectories:YES attributes:nil error:NULL];
}

#pragma mark - instance state

static pid_t ReadPid(NSString *name) {
  NSString *path = [StateDir stringByAppendingPathComponent:[name stringByAppendingString:@".pid"]];
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  long long value = [text longLongValue];
  return value > 0 ? (pid_t)value : 0;
}

// The pid file holds the instance's main process. A stale pid (crash, reuse) is
// caught by comparing the live process image against the shared T3 binary.
static BOOL InstanceIsRunning(pid_t pid) {
  if (pid <= 0) return NO;
  char path[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
  return strcmp(path, ExecPath.fileSystemRepresentation) == 0;
}

static NSString *ReadLast(void) {
  NSString *path = [StateDir stringByAppendingPathComponent:@"last"];
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  NSString *value = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return value && [InstanceNames containsObject:value] ? value : InstanceNames.firstObject;
}

static void WriteLast(NSString *name) {
  NSString *path = [StateDir stringByAppendingPathComponent:@"last"];
  [[name stringByAppendingString:@"\n"] writeToFile:path atomically:YES
                                        encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - window server

// Layer-0 window owners, front to back. The order of the first window belonging
// to one of ours is its most-recently-used rank.
static NSArray<NSNumber *> *WindowOwnerPids(void) {
  CFArrayRef info = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  if (!info) return @[];
  NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
  for (NSDictionary *window in (__bridge_transfer NSArray *)info) {
    if ([window[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
    NSNumber *pid = window[(__bridge NSString *)kCGWindowOwnerPID];
    if (pid) [pids addObject:pid];
  }
  return pids;
}

static pid_t FocusedPid(void) {
  NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
  return front ? front.processIdentifier : 0;
}

static BOOL Activate(pid_t pid) {
  NSRunningApplication *app =
      [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  if (!app) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSApplicationActivationOptions options =
      NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps;
#pragma clang diagnostic pop
  return [app activateWithOptions:options];
}

static void OpenApps(NSArray<NSString *> *paths) {
  NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:@"/usr/bin/open"];
  [argv addObjectsFromArray:paths];
  pid_t pid = 0;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  char **cargv = calloc(argv.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < argv.count; i++) {
    cargv[i] = strdup(argv[i].fileSystemRepresentation);
  }
  if (posix_spawn(&pid, "/usr/bin/open", &actions, NULL, cargv, environ) == 0) {
    int status = 0;
    waitpid(pid, &status, 0);
  }
  posix_spawn_file_actions_destroy(&actions);
  for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
  free(cargv);
}

#pragma mark - decision

// Index of the instance whose main process is pid, or -1.
static NSInteger IndexOfPid(NSArray<NSNumber *> *pids, pid_t pid) {
  for (NSUInteger i = 0; i < pids.count; i++) {
    if (pids[i].intValue == pid) return (NSInteger)i;
  }
  return -1;
}

// Most recently used running instance other than `away` (-1 for none), ranked
// by the window order front to back. A closed, minimized or off-Space window is
// not in that order, so such an instance is picked only after `fallbackName`
// and the remaining running ones in configuration order.
static NSInteger RankedTarget(NSArray<NSNumber *> *pids, NSArray<NSNumber *> *up,
                              NSInteger away, NSString *fallbackName) {
  NSInteger target = -1;
  for (NSNumber *pid in WindowOwnerPids()) {
    NSInteger index = IndexOfPid(pids, pid.intValue);
    if (index >= 0 && index != away && up[index].boolValue) {
      target = index;
      break;
    }
  }
  if (target < 0) {
    NSUInteger last = [InstanceNames indexOfObject:fallbackName];
    if (last != NSNotFound && (NSInteger)last != away && up[last].boolValue) {
      target = (NSInteger)last;
    }
  }
  if (target < 0) {
    for (NSUInteger i = 0; i < pids.count; i++) {
      if ((NSInteger)i != away && up[i].boolValue) {
        target = (NSInteger)i;
        break;
      }
    }
  }
  return target;
}

// Returns the name of the instance to bring forward and records it as the last
// one focused here. With dryRun it only decides.
static NSString *DoWork(BOOL dryRun) {
  NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
  NSMutableArray<NSNumber *> *up = [NSMutableArray array];
  NSInteger running = 0;
  for (NSString *name in InstanceNames) {
    pid_t pid = ReadPid(name);
    BOOL isUp = InstanceIsRunning(pid);
    [pids addObject:@(pid)];
    [up addObject:@(isUp)];
    if (isUp) running++;
  }

  if (running == 0) {
    if (!dryRun) {
      WriteLast(InstanceNames.firstObject);
      OpenApps(AppPaths);
    }
    return InstanceNames.firstObject;
  }

  NSInteger target = -1;
  if (running == 1) {
    for (NSUInteger i = 0; i < up.count; i++) {
      if (up[i].boolValue) {
        target = (NSInteger)i;
        break;
      }
    }
  } else {
    // Switch away from the instance the user is in: the focused application
    // when it is one of ours, else the owner of the frontmost of our windows.
    NSInteger away = IndexOfPid(pids, FocusedPid());
    if (away < 0 || !up[away].boolValue) {
      away = -1;
      for (NSNumber *pid in WindowOwnerPids()) {
        NSInteger index = IndexOfPid(pids, pid.intValue);
        if (index >= 0 && up[index].boolValue) {
          away = index;
          break;
        }
      }
    }
    target = RankedTarget(pids, up, away, ReadLast());
  }

  NSString *name = InstanceNames[target];
  if (!dryRun) {
    if (!Activate(pids[target].intValue)) {
      OpenApps(@[AppPaths[target]]);
    }
    WriteLast(name);
  }
  return name;
}

#pragma mark - helper

static NSString *SelfPath(void) {
  char buffer[PATH_MAX];
  uint32_t size = sizeof(buffer);
  if (_NSGetExecutablePath(buffer, &size) != 0) return nil;
  return [NSString stringWithUTF8String:buffer];
}

static NSString *SocketPath(void) {
  return [StateDir stringByAppendingPathComponent:@"focus.sock"];
}

static BOOL SocketIsLive(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
  BOOL live = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
  close(fd);
  return live;
}

static NSDictionary *BinaryStamp(NSString *path) {
  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
  return @{
    NSFileModificationDate : attributes[NSFileModificationDate] ?: [NSDate distantPast],
    NSFileSize : attributes[NSFileSize] ?: @0,
  };
}

static int Serve(void) {
  NSString *selfPath = SelfPath();
  NSString *socketPath = SocketPath();
  const char *cpath = socketPath.fileSystemRepresentation;

  signal(SIGPIPE, SIG_IGN);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) Die("cannot create socket");

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, cpath, sizeof(addr.sun_path));

  // A socket file can outlive its helper: probe before unlinking, then retry.
  for (int attempt = 0; attempt < 3; attempt++) {
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) break;
    if (SocketIsLive(cpath)) return 0;
    unlink(cpath);
    if (attempt == 2) return 1;
  }
  if (listen(fd, 8) != 0) return 1;
  chmod(cpath, 0600);

  // Warm the window-server connection now so the first request is quick too.
  WindowOwnerPids();
  FocusedPid();

  NSDictionary *stamp = BinaryStamp(selfPath);
  for (;;) {
    int client = accept(fd, NULL, NULL);
    if (client < 0) {
      if (errno == EINTR) continue;
      return 1;
    }
    @autoreleasepool {
      char request[32];
      ssize_t got = recv(client, request, sizeof(request), 0);
      // A probe connect sends nothing; only a "focus" request does work.
      if (got > 0 && memcmp(request, "focus", 5) == 0) {
        if (![BinaryStamp(selfPath) isEqualToDictionary:stamp]) {
          close(client);
          break;
        }
        NSString *name = DoWork(NO);
        dprintf(client, "%s\n", name.UTF8String);
      }
    }
    close(client);
  }
  unlink(cpath);
  return 0;
}

#pragma mark - client

// Returns the name the helper focused, or nil when no helper is available.
static NSString *AskHelper(void) {
  NSString *path = SocketPath();
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return nil;

  struct timeval timeout = {0, 250000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path));
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return nil;
  }
  if (write(fd, "focus", 5) != 5) {
    close(fd);
    return nil;
  }
  char buffer[64];
  ssize_t got = read(fd, buffer, sizeof(buffer) - 1);
  close(fd);
  if (got <= 0) return nil;
  buffer[got] = 0;
  NSString *reply = [[NSString stringWithUTF8String:buffer]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return reply.length > 0 ? reply : nil;
}

static void SpawnHelper(void) {
  NSString *selfPath = SelfPath();
  if (!selfPath) return;

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  int null = open("/dev/null", O_RDWR);
  if (null >= 0) {
    posix_spawn_file_actions_adddup2(&actions, null, 0);
    posix_spawn_file_actions_adddup2(&actions, null, 1);
    posix_spawn_file_actions_adddup2(&actions, null, 2);
    posix_spawn_file_actions_addclose(&actions, null);
  }
  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  // Own session, and close everything the caller has open beyond stdio: the
  // helper must not hold a terminal, a pipe or a Raycast pipe open forever.
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);

  char *self = strdup(selfPath.fileSystemRepresentation);
  char *argv[] = {self, "--helper", NULL};
  pid_t pid = 0;
  posix_spawn(&pid, selfPath.fileSystemRepresentation, &actions, &attributes, argv, environ);
  free(self);

  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  if (null >= 0) close(null);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    BOOL helper = NO, dryRun = NO;
    for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "--helper") == 0) {
        helper = YES;
      } else if (strcmp(argv[i], "--dry-run") == 0) {
        dryRun = YES;
      } else {
        fprintf(stderr, "usage: focus [--helper] [--dry-run]\n");
        return 2;
      }
    }

    LoadConfig();
    if (helper) return Serve();

    NSString *name = nil;
    if (dryRun) {
      name = DoWork(YES);
    } else {
      name = AskHelper();
      if (!name) {
        name = DoWork(NO);
        SpawnHelper();
      }
    }
    printf("%s\n", name.UTF8String);
    return 0;
  }
}
