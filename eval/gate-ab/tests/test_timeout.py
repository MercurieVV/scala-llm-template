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

class SecondSignal(unittest.TestCase):
    def test_second_signal_during_grace_still_kills(self):
        # child ignores SIGTERM, so timeout.py sits in its 10 s grace; a second signal there must not skip the SIGKILL
        with tempfile.TemporaryDirectory() as d:
            pidfile = os.path.join(d, "pid")
            p = subprocess.Popen([sys.executable, TIMEOUT, "60", "--", "sh", "-c", 'trap "" TERM; echo $$ > "%s"; exec sleep 100 2>/dev/null' % pidfile],
                                 stderr=subprocess.PIPE)
            for _ in range(100):
                if os.path.exists(pidfile) and slurp(pidfile): break
                time.sleep(0.1)
            child = int(slurp(pidfile))
            p.send_signal(signal.SIGTERM); time.sleep(1)
            p.send_signal(signal.SIGINT); time.sleep(0.5); p.send_signal(signal.SIGTERM)
            rc = p.wait(timeout=30); err = p.stderr.read().decode(); p.stderr.close()
            for _ in range(50):
                try: os.kill(child, 0)
                except ProcessLookupError: break
                time.sleep(0.1)
            else:
                os.kill(child, signal.SIGKILL); self.fail("child survived a second signal during reap; stderr=%r" % err)
            self.assertEqual(rc, 130); self.assertNotIn("Traceback", err)

if __name__ == "__main__":
    unittest.main()
