#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import socket
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resolver', Path(__file__).with_name('resolve-ipv4.py'))
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class IPv4(unittest.TestCase):
    def test_unique_sorted_stream_ipv4(self):
        rows = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', (ip, 0))
                for ip in ['192.0.2.2', '192.0.2.1', '192.0.2.2']]
        with patch.object(socket, 'getaddrinfo', return_value=rows) as lookup:
            self.assertEqual(resolver.resolve('fixture'), ['192.0.2.1', '192.0.2.2'])
            lookup.assert_called_once_with('fixture', None, socket.AF_INET, socket.SOCK_STREAM)

    def test_resolution_failure(self):
        with patch.object(socket, 'getaddrinfo', side_effect=socket.gaierror('unavailable')):
            with self.assertRaises(socket.gaierror):
                resolver.resolve('fixture')

    def test_real_loopback(self):
        self.assertEqual(resolver.resolve('127.0.0.1'), ['127.0.0.1'])


if __name__ == '__main__':
    unittest.main()
