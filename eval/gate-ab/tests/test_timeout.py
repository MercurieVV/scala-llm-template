import os, signal, subprocess, sys, tempfile, time, unittest, pathlib
HERE = pathlib.Path(__file__).parent
TIMEOUT = str(HERE.parent / "timeout.py")

def slurp(p):
    with open(p) as f:
        return f.read().strip()

class Interrupt(unittest.TestCase):
    def test_sigint_kills_the_child_group(self):
        self.check(signal.SIGINT)
    def test_sigterm_kills_the_child_group(self):
        self.check(signal.SIGTERM)
    def check(self, sig):
        with tempfile.TemporaryDirectory() as d:
            pidfile = os.path.join(d, "pid")
            p = subprocess.Popen([sys.executable, TIMEOUT, "60", "--", "sh", "-c", 'echo $$ > "%s"; exec sleep 100' % pidfile])
            for _ in range(100):
                if os.path.exists(pidfile) and slurp(pidfile): break
                time.sleep(0.1)
            child = int(slurp(pidfile))
            p.send_signal(sig)
            self.assertNotEqual(p.wait(timeout=30), 0)
            for _ in range(100):
                try: os.kill(child, 0)
                except ProcessLookupError: break
                time.sleep(0.1)
            else:
                os.kill(child, signal.SIGKILL); self.fail("child survived %s to timeout.py" % sig)

if __name__ == "__main__":
    unittest.main()
