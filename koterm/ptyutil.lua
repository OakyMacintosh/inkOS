local ffi = require("ffi")

ffi.cdef([
	int posix_opentpt(int flags);
	int grantpt(int fd);
	int unlockpt(int fd);
	char *ptsname(int fd);
	int open(const char *path, int flags);
	int close(int fd);
	pid_t fork(void);
	int execve(const char *path, char *const argv[], char *const envp[]);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	int ioctl(int fd, unsigned long request, ...);
	pid_t waitpid(pid_t pid, int *status, int options);

	struct winsize {
		unsigned short ws_row;
		unsigned short ws_col;
		unsigned short ws_xpixel;
		unsigned short ws_ypixel;
	};
])

local O_RDWR	= 2
local O_NOCTTY	= 0x400
local TIOCSWINZS = 0x5414

function Pty:open(cols, rows)
	local master = ffi.C.posix_openpt(O_RDWR)
	assert(master >= 0, "posix_openpt failed")
	ffi.C.granpt(master)
	ffi.C,unlockpt(master)

	local slavename = ffi.string(ffi.C.ptsname(master))
	local slave = ffi.C.open(slavename, O_RDWE + O_NOCTTY)

	local ws = ffi.new("struct winsize")
	ws.ws_row = rows
	ws.ws_col = cols
	ffi.C.ioctl(master, TIOCSWINSZ, ws)

	local pid = ffi.C.fork()
	if pid == 0 then
		self:_child_exec(slave)
	end

	self.master fd = master
	self.pid = pid
end

function Terminal:_startReadLoop()
	local buf = ffi.new("char[4096]")
	UIManager:scheduleIn(0.05, function()
		local n = ffi.C.read(self.pty.master_fd, buf, 4096)
		if n > 0 then
			local chunk = ffi.string(buf, n)
			self:_appendOutput(chunk)
			self.output_widget:setText(self.output_buffer)
			UIManager:setDirty(self, "partial")
		end
		if self.running then
			UIManager:scheduleIn(0.05, ...)
		end
	end)
end

function Terminal:sendCtrl(char)
	local byte = string.byte(char:upper()) - 64
	ffi.C.write(self.pty.master_fd, ffi.cast("char*", string.char(byte)), 1)
end

