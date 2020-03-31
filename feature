#!/usr/bin/env python3

""" Tool for managing features across multiple Android projects """

import argparse
import importlib
import json
import os
import os.path
import subprocess
from subprocess import PIPE
import sys


def interpret_abandon_result(project, branch, result):
    """ Interpret the result of an abandon operation """

    if result is None:
        print('Branch', branch, 'not found in', project)
        return

    if result:
        print('Branch', branch, 'abandoned in', project)
    else:
        print('Failed to abandon branch', branch, 'in', project)


def interpret_checkout_result(project, branch, result):
    """ Interpret the result of a check-out operation """

    if result is None:
        print('Branch', branch, 'not found in', project)
        return

    if result:
        print('Branch', branch, 'checked-out in', project)
    else:
        print('Failed to check-out branch', branch, 'in', project)


def locate_repo():
    """ Look for a repo directory, starting at the current directory  """

    curdir = os.getcwd()
    repo = None

    olddir = None
    while curdir != '/'  and curdir != olddir  and not repo:
        repo = os.path.join(curdir, '.repo')

        if not os.path.isdir(repo):
            repo = None
            olddir = curdir
            curdir = os.path.dirname(curdir)

    return repo


def normalize_and_validate_path(path, repo, manifest):
    """ Normalize path and check that it is a valid project """

    normalized_path = repo.normalize_path(path)
    if not normalized_path:
        print('Path', path, 'is not part of the source tree')
        sys.exit(1)

    if normalized_path not in manifest.projects():
        print('Path', path, 'is not a valid project path')
        sys.exit(1)

    return normalized_path


class FeatureLock(): # pylint: disable=too-few-public-methods
    """ Manage the feature lock file """

    def __init__(self, path):
        self.path = os.path.join(path, '.feature_lock')

    def __enter__(self):
        """ Check for an existing lock and create one """

        try:
            with open(self.path, 'x') as lock_file:
                lock_file.write(str(os.getpid()) + '\n')
        except FileExistsError:
            print('Simultaneous calls detected. Please complete the other operation and try again')
            sys.exit(2)

    def __exit__(self, exc_type, exc_val, exc_tb):
        """ Clean-up lock file """

        os.remove(self.path)


class Repo():
    """ The repo """

    def __init__(self):
        self.path = locate_repo()

        if not self.path:
            print('Could not find repo directory')
            sys.exit(1)

        sys.path.insert(0, os.path.join(self.path, 'repo'))

    def manifest(self):
        """ Get repo manifest """

        return ManifestData(self.path)

    def normalize_path(self, path):
        """ Check that a path is located in the repo soure tree and
            make it relative to the root of the source tree         """

        full_path = os.path.abspath(path)

        if os.path.commonprefix([full_path, self.source_dir()]) != self.source_dir():
            return None

        return os.path.relpath(full_path, self.source_dir())

    def source_dir(self):
        """ Get top of source tree """

        return os.path.dirname(self.path)


class ManifestData(): # pylint: disable=too-few-public-methods
    """ Access information from the repo manifest """

    def __init__(self, path):
        module = importlib.import_module('manifest_xml')
        xml_manifest_class = getattr(module, 'XmlManifest')
        self.manifest = xml_manifest_class(path)

    def projects(self):
        """ Return a dictionary of projects keyed by project paths """

        return self.manifest.paths


class FeatureData():
    """ Data about the features and projects """

    def __init__(self, path):
        self.path = os.path.join(path, '.feature_data')
        self.data_file = None
        self.feature_data = None

    def __enter__(self):
        """ Open or create the data file and upgrade or initialize it as necessary """

        try:
            self.data_file = open(self.path, 'r+t')
            self.feature_data = json.load(self.data_file)
        except FileNotFoundError:
            self.data_file = open(self.path, 'w+t')
            self.feature_data = {}

        self._init_or_upgrade_data()

        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """ Update and close the data file """

        self.data_file.seek(0)
        json.dump(self.feature_data, self.data_file, indent=4)
        self.data_file.truncate()
        self.data_file.close()

    def _init_or_upgrade_data(self):
        if 'active_feature' not in self.feature_data:
            self.feature_data['active_feature'] = None

        if 'features' not in self.feature_data:
            self.feature_data['features'] = {}

        for name, feature in self.feature_data['features'].items():
            if 'name' not in feature:
                feature['name'] = name

            if 'default_branch' not in feature:
                feature['default_branch'] = name

            if 'current_project' not in feature:
                feature['current_project'] = None

            if 'projects' not in feature:
                feature['projects'] = {}

                for path, project in feature['projects'].items():
                    if 'path' not in project:
                        project['path'] = path

                    if 'branch' not in project:
                        project['branch'] = None

    def active_feature(self, *, must_be_defined=False):
        """ The key of the active feature """

        feature = self.feature_data['active_feature']

        if must_be_defined and not feature:
            print('There is no active feature')
            sys.exit(1)

        return feature

    def add_project(self, feature, path, branch):
        """ Add a project to the specified feature if it doesn't already exist """

        self.feature_data['features'][feature]['projects'][path] = { \
                'path': path, \
                'branch': branch \
            }

    def clear_active_feature(self):
        """ Clear the active feature"""

        self.feature_data['active_feature'] = None


    def create_feature(self, name, default_branch):
        """ Create a feature if it doesn't already exist """

        if not default_branch:
            default_branch = name

        self.feature_data['features'][name] = { \
                'name': name, \
                'default_branch': default_branch \
            }

    def delete_feature(self, name):
        """ Delete a feature """

        del self.feature_data['features'][name]

    def default_branch(self, feature):
        """ Return the default branch for the specified feature """

        return self.feature_data['features'][feature]['default_branch']

    def feature(self, feature):
        """ Return data for the specified feature """

        return self.feature_data['features'][feature]

    def feature_list(self):
        """ Return a list of feature names """

        return self.feature_data['features'].keys()

    def project(self, feature, project):
        """ Return data for the specified project of the specified feature """

        return self.feature_data['features'][feature]['projects'][project]

    def project_branch(self, feature, project):
        """ Return the project's branch name """

        branch = self.feature_data['features'][feature]['projects'][project]['branch']
        if not branch:
            branch = self.feature_data['features'][feature]['default_branch']

        return branch

    def project_list(self, feature):
        """ Return a list of projects in the specified feature """

        return self.feature_data['features'][feature]['projects'].keys()

    def remove_project(self, feature, path):
        """ Remove a project from the specified feature """

        del self.feature_data['features'][feature]['projects'][path]

    def set_active_feature(self, feature):
        """ Set the specified feature as the active feature """

        self.feature_data['active_feature'] = feature

    def validate_feature(self, feature, *, may_default_to_active=False, must_exist=False, \
            must_not_exist=False, must_be_active=False, must_not_be_active=False):
        """ Verify that the specified feature meets the specified criteria """

        if not feature:
            if may_default_to_active:
                feature = self.active_feature()
                if not feature:
                    print('There is no active feature')
                    sys.exit(1)
            else:
                raise RuntimeError('Feature is falsy and may_default_to_active is False')

        if must_exist and feature not in self.feature_list():
            print('Feature', feature, 'does not exist')
            sys.exit(1)

        if must_not_exist and feature in self.feature_list():
            print('Feature', feature, 'already exists')
            sys.exit(1)

        is_active = (feature == self.active_feature())

        if must_be_active and not is_active:
            print('Feature', feature, 'must be the active feature')
            sys.exit(1)

        if must_not_be_active and is_active:
            print('Feature', feature, 'must not be the active feature')
            sys.exit(1)

        return feature, is_active

    def validate_project(self, feature, path, *, must_exist=False, must_not_exist=False):
        """ Verify that the specified project meets the specified criteria """

        if must_exist and path not in self.project_list(feature):
            print('Project', path, 'is not part of feature', feature)
            sys.exit(1)

        if must_not_exist and path in self.project_list(feature):
            print('Project', path, 'is already part of feature', feature)
            sys.exit(1)

        return feature, path


class AddSubcommand(): # pylint: disable=no-self-use
    """ Add a project to a feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'add', \
                help='add a project to a feature' \
            )
        parser.add_argument( \
                'path', \
                type=str, \
                help='project path' \
            )
        parser.add_argument( \
                '-f', \
                '--feature', \
                help='feature name (default is active feature)' \
            )
        group = parser.add_mutually_exclusive_group()
        group.add_argument( \
                '-b', \
                '--branch', \
                help='name of branch to create (overrides feature default branch name)' \
            )
        group.add_argument( \
                '-a', \
                '--adopt', \
                metavar='BRANCH', \
                help='name of existing branch to adopt (if not specified, \
                    a new branch is created)' \
            )
        parser.set_defaults(func=AddSubcommand.run)

    def run(self, args, data, repo):
        """ Execute the command """

        if args.branch:
            branch = args.branch
            adopt = False
        else:
            if args.adopt:
                branch = args.adopt
                adopt = True
            else:
                branch = None
                adopt = False

        feature, is_active = data.validate_feature(args.feature, may_default_to_active=True, \
                must_exist=True)

        manifest = repo.manifest()

        path = normalize_and_validate_path(args.path, repo, manifest)

        data.validate_project(feature, path, must_not_exist=True)

        project = manifest.projects()[path]

        if not is_active:
            data.set_active_feature(feature)
            print('Feature', feature, 'is now active')

        data.add_project(feature, path, branch)

        if not branch:
            branch = data.default_branch(feature)

        if not adopt:
            interpret_checkout_result(path, branch, project.StartBranch(branch))
        else:
            interpret_checkout_result(path, branch, project.CheckoutBranch(branch))


class CheckoutSubcommand(): # pylint: disable=no-self-use
    """ Checkout project branches """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'checkout', \
                help='checkout project branches' \
            )
        parser.add_argument( \
                '-f', \
                '--feature', \
                help='feature name (default is active feature)' \
            )
        parser.set_defaults(func=CheckoutSubcommand.run)

    def run(self, args, data, repo):
        """ Execute the command """

        feature, is_active = data.validate_feature(args.feature, may_default_to_active=True, \
                must_exist=True)

        if not is_active:
            data.set_active_feature(feature)
            print('Feature', feature, 'is now active')

        manifest = repo.manifest()

        for path in data.project_list(feature):
            branch = data.project_branch(feature, path)
            project = manifest.projects()[path]
            interpret_checkout_result(path, branch, project.CheckoutBranch(branch))


class ClearSubcommand(): # pylint: disable=no-self-use
    """ Clear the active feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'clear', \
                help='clear the active feature' \
            )
        parser.set_defaults(func=ClearSubcommand.run)

    def run(self, _1, data, _2):
        """ Execute the command """

        data.clear_active_feature()

        print('Active feature cleared')


class CreateSubcommand(): # pylint: disable=no-self-use
    """ Create a new feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'create', \
                help='create a new feature' \
            )
        parser.add_argument( \
                'name', \
                type=str, \
                help='feature name' \
            )
        parser.add_argument( \
                '-b', \
                '--branch', \
                help='default branch name (if not specified, feature name is used)' \
            )
        parser.add_argument( \
                '-a', \
                '--active', \
                action='store_true', \
                help='make the new feature the active feature' \
            )
        parser.set_defaults(func=CreateSubcommand.run)

    def run(self, args, data, _):
        """ Execute the command """

        name = data.validate_feature(args.name, must_not_exist=True)[0]

        data.create_feature(name, args.branch)

        if args.active:
            data.set_active_feature(name)
            print('Feature', name, 'is now active')


class DeleteSubcommand(): # pylint: disable=no-self-use
    """ Delete a feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'delete', \
                help='delete a feature' \
            )
        parser.add_argument( \
                'name', \
                type=str, \
                help='name of feature to delete' \
            )
        parser.add_argument( \
                '-d', \
                '--delete-branches', \
                action='store_true', \
                help='delete the feature branch from all the projects' \
            )
        parser.set_defaults(func=DeleteSubcommand.run)

    def run(self, args, data, repo):
        """ Execute the command """

        name = data.validate_feature(args.name, must_exist=True, must_not_be_active=True)[0]

        manifest = repo.manifest()

        if args.delete_branches:
            for path in data.project_list(name):
                project = manifest.projects()[path]
                branch = data.project_branch(name, path)
                interpret_abandon_result(path, branch, project.AbandonBranch(branch))

        data.delete_feature(name)


class ListSubcommand(): # pylint: disable=no-self-use
    """ List features """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'list', \
                help='list features' \
            )
        parser.set_defaults(func=ListSubcommand.run)

    def run(self, _1, data, _2):
        """ Execute the command """

        features = data.feature_list()
        if features:
            for key in features:
                if key == data.active_feature():
                    active = '*'
                else:
                    active = ' '

                feature = data.feature(key)
                print('%sFeature %s (default branch: %s)' % \
                        (active, feature['name'], feature['default_branch']))
        else:
            print('No features defined')


class RemoveSubcommand(): # pylint: disable=no-self-use
    """ Remove a project from a feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'remove', \
                help='remove a project from a feature' \
            )
        parser.add_argument( \
                'path', \
                type=str, \
                help='project path' \
            )
        parser.add_argument( \
                '-f', \
                '--feature', \
                help='feature name (default is active feature)' \
            )
        parser.add_argument( \
                '-d', \
                '--delete-branch', \
                action='store_true', \
                help='delete the feature branch from the project' \
            )
        parser.set_defaults(func=RemoveSubcommand.run)

    def run(self, args, data, repo):
        """ Execute the command """

        feature = data.validate_feature(args.feature, may_default_to_active=True, \
                must_exist=True)[0]

        manifest = repo.manifest()

        path = normalize_and_validate_path(args.path, repo, manifest)

        data.validate_project(feature, path, must_exist=True)

        if args.delete_branch:
            branch = data.project_branch(feature, path)
            project = manifest.projects()[path]
            interpret_abandon_result(path, branch, project.AbandonBranch(branch))

        data.remove_project(feature, path)


class ResetSubcommand(): # pylint: disable=no-self-use
    """ Reset project branches of the active feature to manifest default """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'reset', \
                help='reset project branches of the active feature to manifest default' \
            )
        parser.set_defaults(func=ResetSubcommand.run)

    def run(self, _, data, repo):
        """ Execute the command """

        feature = data.active_feature(must_be_defined=True)

        manifest = repo.manifest()

        for path in data.project_list(feature):
            project = manifest.projects()[path]
            branch = project.dest_branch
            if not branch:
                branch = project.revisionExpr
            interpret_checkout_result(path, branch, project.CheckoutBranch(branch))


class SelectSubcommand(): # pylint: disable=no-self-use
    """ Activate the specified feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'select', \
                help='activate a feature' \
            )
        parser.add_argument( \
                'feature', \
                type=str, \
                help='feature to make active' \
            )
        parser.set_defaults(func=SelectSubcommand.run)

    def run(self, args, data, _):
        """ Execute the command """

        feature, is_active = data.validate_feature(args.feature, must_exist=True)

        if not is_active:
            data.set_active_feature(feature)
            print('Feature', feature, 'is now active')
        else:
            print('Feature', feature, 'is already active')


class ShellSubcommand(): # pylint: disable=no-self-use
    """ Open a shell or run a shell command in each project of the active feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'shell', \
                help='open a shell or run a shell command in each project of the active feature' \
            )
        parser.add_argument( \
                '-c', \
                '--command', \
                type=str, \
                nargs=argparse.REMAINDER, \
                help='command to run (default is to open a shell)' \
            )
        parser.set_defaults(func=ShellSubcommand.run)

    def run(self, args, data, _):
        """ Execute the command """

        feature = data.active_feature(must_be_defined=True)

        repo = locate_repo()
        if not repo:
            print('Could not find repo directory')
            sys.exit(1)

        top = os.path.dirname(repo)
        shell = os.environ['SHELL']

        for path in data.project_list(feature):
            print('* Project', path, '*')
            if args.command:
                subprocess.run(' '.join(args.command), \
                        shell=True, \
                        cwd=os.path.join(top, path), \
                        check=False)
                print()
            else:
                subprocess.run(shell, \
                        shell=False, \
                        cwd=os.path.join(top, path), \
                        check=False)

        print('* Done *')

class ShowSubcommand(): # pylint: disable=no-self-use
    """ List the projects of a feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'show', \
                help='list the projects of a feature' \
            )
        parser.add_argument( \
                '-f', \
                '--feature', \
                help='feature to list (default is active feature)' \
            )
        parser.set_defaults(func=ShowSubcommand.run)

    def run(self, args, data, _):
        """ Execute the command """

        feature = data.validate_feature(args.feature, may_default_to_active=True, \
                must_exist=True)[0]

        projects = data.project_list(feature)
        if projects:
            print('* Feature', feature, '*')

            for key in projects:
                project = data.project(feature, key)
                branch = project['branch']
                if not branch:
                    branch = data.default_branch(feature) + ', feature default'

                print('Project %s (branch: %s)' % (key, branch))
        else:
            print('Feature', feature, 'has no projects')


class StatusSubcommand(): # pylint: disable=no-self-use
    """ Show the status of each project in the active feature """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'status', \
                help='show the status of each project in the active feature' \
            )
        parser.set_defaults(func=StatusSubcommand.run)

    def run(self, _, data, repo):
        """ Execute the command """

        feature = data.active_feature(must_be_defined=True)

        print('* Feature', feature, '*')

        # Old versions of repo are not compatible with Python 3
        # and PrintWorkTreeStatus throws an exception sometimes
        completed = subprocess.run('repo version', shell=True, check=True, stdout=PIPE)
        if completed.stdout.find(b'repo version v1') == -1:
            manifest = repo.manifest()

            for path in data.project_list(feature):
                project = manifest.projects()[path]
                project.PrintWorkTreeStatus()
        else:
            python2_script = os.path.join( \
                    os.path.dirname(os.path.abspath(__file__)), 'feature_status_python2')
            command = [python2_script] + list(data.project_list(feature))
            subprocess.run(command, check=True)


class FeatureCommand(): # pylint: disable=too-few-public-methods
    """ Implements feature commands """

    def __init__(self):
        self.commands = [ \
                AddSubcommand(), \
                CheckoutSubcommand(), \
                ClearSubcommand(), \
                CreateSubcommand(), \
                DeleteSubcommand(), \
                ListSubcommand(), \
                RemoveSubcommand(), \
                ResetSubcommand(), \
                SelectSubcommand(), \
                ShellSubcommand(), \
                ShowSubcommand(), \
                StatusSubcommand() \
            ]

        self.parser = argparse.ArgumentParser()
        subparsers = self.parser.add_subparsers( \
                dest='sub-command', \
                help='sub-command to run' \
            )
        subparsers.required = True

        for command in self.commands:
            command.add_parser(subparsers)

    def parse_and_run(self, data, repo):
        """ Parse the command and run it """

        args = self.parser.parse_args()
        args.func(None, args, data, repo)


def main():
    """ Main """

    repo = Repo()
    feature_dir = repo.source_dir()

    with FeatureLock(feature_dir):
        with FeatureData(feature_dir) as data:
            FeatureCommand().parse_and_run(data, repo)

main()

# vim: colorcolumn=100
