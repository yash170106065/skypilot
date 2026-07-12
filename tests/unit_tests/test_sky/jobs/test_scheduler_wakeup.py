"""Tests for managed-jobs scheduler controller wakeups."""
# pylint: disable=protected-access

import os
import shutil
import tempfile

from sky.jobs import scheduler


def test_wake_controllers_without_registered_controller(tmp_path, monkeypatch):
    monkeypatch.setattr(scheduler, 'JOB_CONTROLLER_WAKEUP_DIR', str(tmp_path))
    scheduler._wake_controllers()


def test_wake_controllers_sends_datagram(monkeypatch):
    wake_dir = tempfile.mkdtemp(prefix='sky-wakeup-', dir='/tmp')
    monkeypatch.setattr(scheduler, 'JOB_CONTROLLER_WAKEUP_DIR', wake_dir)
    wake_socket, socket_path = scheduler.create_controller_wakeup_socket(
        'controller-id')
    try:
        scheduler._wake_controllers()
        assert wake_socket.recv(16) == b'wake'
    finally:
        wake_socket.close()
        os.unlink(socket_path)
        shutil.rmtree(wake_dir)
