"""Unit tests for managed-K8s launch-path optimizations."""
# pylint: disable=protected-access

from unittest.mock import call
from unittest.mock import MagicMock
from unittest.mock import patch

import pytest

from sky import clouds
from sky import exceptions
from sky.backends import cloud_vm_ray_backend
from sky.utils import status_lib


class TestManagedKubernetesGrpcLaunch:
    """Tests for the managed-Kubernetes launch-control fast path."""

    @staticmethod
    def _make_handle(grpc_capable: bool = True):
        handle = MagicMock()
        handle.is_grpc_enabled = grpc_capable
        handle.is_grpc_enabled_with_flag = False
        handle.launched_resources.cloud = clouds.Kubernetes()
        handle.cluster_name = 'managed-k8s'
        handle.provision_runtime_metadata.has_skylet = True
        return handle

    @staticmethod
    def _make_backend(is_managed_job: bool = True):
        backend = cloud_vm_ray_backend.CloudVmRayBackend()
        backend._is_launched_by_jobs_controller = is_managed_job
        return backend

    def test_prefers_grpc_for_capable_managed_kubernetes(self):
        backend = self._make_backend()
        handle = self._make_handle()
        assert backend._use_grpc_for_managed_job_launch(handle)

    def test_explicit_false_disables_automatic_grpc(self, monkeypatch):
        backend = self._make_backend()
        handle = self._make_handle()
        monkeypatch.setenv(
            cloud_vm_ray_backend.env_options.Options.ENABLE_GRPC.env_key, '0')
        assert not backend._use_grpc_for_managed_job_launch(handle)

    @pytest.mark.parametrize('is_managed_job,grpc_capable', [(False, True),
                                                             (True, False)])
    def test_retains_legacy_path_without_both_requirements(
            self, is_managed_job, grpc_capable):
        backend = self._make_backend(is_managed_job)
        handle = self._make_handle(grpc_capable)
        assert not backend._use_grpc_for_managed_job_launch(handle)

    def test_add_job_falls_back_to_ssh(self):
        backend = self._make_backend()
        handle = self._make_handle()
        backend.run_on_head = MagicMock(return_value=(0, '1\n', ''))
        with patch.object(cloud_vm_ray_backend.backend_utils,
                          'invoke_skylet_with_retries',
                          side_effect=exceptions.SkyletUnavailableError):
            job_id, _ = backend._add_job(handle, 'job', 'resources', '{}')
        assert job_id == 1
        backend.run_on_head.assert_called_once()

    def test_queue_job_falls_back_to_ssh(self):
        backend = self._make_backend()
        handle = self._make_handle()
        backend.run_on_head = MagicMock(return_value=(0, '', ''))
        with patch.object(cloud_vm_ray_backend.backend_utils,
                          'invoke_skylet_with_retries',
                          side_effect=exceptions.SkyletUnavailableError):
            backend._exec_code_on_head(handle, 'print("hello")', job_id=1)
        backend.run_on_head.assert_called_once()

    def test_add_then_queue_order_is_preserved(self):
        backend = self._make_backend()
        handle = self._make_handle()
        client = MagicMock()
        client.add_job.return_value.job_id = 1
        client.add_job.return_value.log_dir = '/tmp/job'
        with patch.object(cloud_vm_ray_backend,
                          'SkyletClient',
                          return_value=client), patch.object(
                              cloud_vm_ray_backend.backend_utils,
                              'invoke_skylet_with_retries',
                              side_effect=lambda operation: operation()):
            job_id, _ = backend._add_job(handle, 'job', 'resources', '{}')
            backend._exec_code_on_head(handle, 'print("hello")', job_id)
        assert client.method_calls == [
            call.add_job(client.add_job.call_args.args[0]),
            call.queue_job(client.queue_job.call_args.args[0]),
        ]

    def test_autodown_falls_back_to_ssh(self):
        backend = self._make_backend()
        handle = self._make_handle()
        backend.run_on_head = MagicMock(return_value=(0, '', ''))
        with patch.object(
                cloud_vm_ray_backend.backend_utils,
                'invoke_skylet_with_retries',
                side_effect=exceptions.SkyletUnavailableError), patch.object(
                    cloud_vm_ray_backend.global_user_state,
                    'set_cluster_autostop_value'), patch.object(
                        cloud_vm_ray_backend.kubernetes_utils,
                        'set_autodown_annotations'):
            backend.set_autostop(handle,
                                 idle_minutes_to_autostop=0,
                                 wait_for=None,
                                 down=True)
        backend.run_on_head.assert_called_once()


class TestFreshClusterLaunchGuards:
    """Fresh clusters must not run reconciliation meant for old runtimes."""

    def test_fresh_cluster_skips_job_queue_refresh(self):
        metadata = (
            cloud_vm_ray_backend.provision_common.ProvisionRuntimeMetadata(
                has_job_queue=True))
        assert not cloud_vm_ray_backend._should_refresh_job_queue(
            None, metadata)

    def test_uncertain_init_cluster_refreshes_job_queue(self):
        metadata = (
            cloud_vm_ray_backend.provision_common.ProvisionRuntimeMetadata(
                has_job_queue=True))
        assert cloud_vm_ray_backend._should_refresh_job_queue(
            status_lib.ClusterStatus.INIT, metadata)

    def test_runtime_without_queue_skips_refresh(self):
        metadata = (
            cloud_vm_ray_backend.provision_common.ProvisionRuntimeMetadata(
                has_job_queue=False))
        assert not cloud_vm_ray_backend._should_refresh_job_queue(
            status_lib.ClusterStatus.INIT, metadata)
