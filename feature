#!/usr/bin/env python3

""" Tool for managing features across multiple Android projects """

import argparse
import importlib
import json
import os
import os.path
import sys


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

        if os.path.commonprefix([full_path, self.source_dir()]) != \
                self.source_dir():
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

    def _validate_feature(self, feature, may_default_to_active=False, \
            must_exist=False, must_not_exist=False):
        if not feature:
            if may_default_to_active:
                feature = self.active_feature()
                if not feature:
                    print('There is no active feature')
                    sys.exit(1)
            else:
                print('Internal error: feature is falsy and may_default_to_active is False')
                sys.exit(2)

        if must_exist and feature not in self.features():
            print('Feature', feature, 'does not exist')
            sys.exit(1)

        if must_not_exist and feature in self.features():
            print('Feature', feature, 'already exists')
            sys.exit(1)

        return feature

    def _validate_project(self, feature, path, must_exist=False, must_not_exist=False):
        if must_exist and path not in self.projects(feature):
            print('Project', path, 'is not part of feature', feature)
            sys.exit(1)

        if must_not_exist and path in self.projects(feature):
            print('Project', path, 'is already part of feature', feature)
            sys.exit(1)

        return feature, path

    def active_feature(self):
        """ The key of the active feature """

        return self.feature_data['active_feature']

    def add_project(self, feature, path, branch):
        """ Add a project to the specified feature if it doesn't already exist """

        feature = self._validate_feature(feature, may_default_to_active=True, must_exist=True)

        self._validate_project(feature, path, must_not_exist=True)

        self.feature_data['features'][feature]['projects'][path] = { \
                'path': path, \
                'branch': branch \
            }

    def create_feature(self, name, default_branch):
        """ Create a feature if it doesn't already exist """

        name = self._validate_feature(name, must_not_exist=True)

        if not default_branch:
            default_branch = name

        self.feature_data['features'][name] = { \
                'name': name, \
                'default_branch': default_branch \
            }

    def default_branch(self, feature):
        """ Return the default branch for the specified feature """

        feature = self._validate_feature(feature, may_default_to_active=True, \
                must_exist=True)

        return self.feature_data['features'][feature]['default_branch']

    def feature(self, feature):
        """ Return data for the specified feature """

        feature = self._validate_feature(feature, may_default_to_active=True, \
                must_exist=True)

        return self.feature_data['features'][feature]

    def features(self):
        """ Return a list of feature names """

        return self.feature_data['features'].keys()

    def list_features(self):
        """ List all the features """

        features = self.features()
        if features:
            for key in features:
                if key == self.active_feature():
                    active = '*'
                else:
                    active = ' '

                feature = self.feature(key)
                print('%sFeature %s (default branch: %s)' % \
                        (active, feature['name'], feature['default_branch']))
        else:
            print('No features defined')

    def list_projects(self, feature):
        """ List projects in the feature """

        feature = self._validate_feature(feature, may_default_to_active=True, \
                must_exist=True)

        projects = self.projects(feature)
        if projects:
            for key in self.projects(feature):
                project = self.project(feature, key)
                branch = project['branch']
                if not branch:
                    branch = self.default_branch(feature) + ', feature default'

                print('Project %s (branch: %s)' % (key, branch))
        else:
            print('Feature', feature, 'has no projects')

    def project(self, feature, project):
        """ Return data for the specified project of the specified feature """

        self._validate_feature(feature, must_exist=True)
        self._validate_project(feature, project, must_exist=True)

        return self.feature_data['features'][feature]['projects'][project]

    def project_branch(self, feature, project):
        """ Return the project's branch name """

        feature = self._validate_feature(feature, may_default_to_active=True, \
                must_exist=True)
        self._validate_project(feature, project, must_exist=True)

        branch = self.feature_data['features'][feature]['projects'][project]['branch']
        if not branch:
            branch = self.feature_data['features'][feature]['default_branch']

        return branch

    def projects(self, feature):
        """ Return a list of projects in the specified feature """

        feature = self._validate_feature(feature, may_default_to_active=True, \
                must_exist=True)

        return self.feature_data['features'][feature]['projects'].keys()

    def set_active_feature(self, feature):
        """ Set the specified feature as the active feature """

        self._validate_feature(feature, must_exist=True)

        self.feature_data['active_feature'] = feature
        print('Feature', feature, 'is now active')


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

        manifest = repo.manifest()

        normalized_path = repo.normalize_path(args.path)
        if not normalized_path:
            print('Path', args.path, 'is not part of the source tree')
            sys.exit(1)

        if normalized_path not in manifest.projects():
            print('Path', args.path, 'is not a valid project path')
            sys.exit(1)

        project = manifest.projects()[normalized_path]

        data.add_project(args.feature, normalized_path, branch)

        if not branch:
            branch = data.default_branch(args.feature)

        if not adopt:
            project.StartBranch(branch)
        else:
            project.CheckoutBranch(branch)


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

        if args.feature and args.feature != data.active_feature():
            data.set_active_feature(args.feature)

        manifest = repo.manifest()

        for path in data.projects(args.feature):
            branch = data.project_branch(args.feature, path)
            project = manifest.projects()[path]
            project.CheckoutBranch(branch)


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

        data.create_feature(args.name, args.branch)

        if args.active:
            data.set_active_feature(args.name)


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

        data.list_features()


class ResetSubcommand(): # pylint: disable=no-self-use
    """ Reset project branches to manifest default """

    def add_parser(self, subparsers):
        """ Add sub-parser for the command """

        parser = subparsers.add_parser( \
                'reset', \
                help='reset project branches to manifest default' \
            )
        parser.set_defaults(func=ResetSubcommand.run)

    def run(self, _, data, repo):
        """ Execute the command """

        manifest = repo.manifest()

        for path in data.projects(data.active_feature()):
            project = manifest.projects()[path]
            project.CheckoutBranch(project.revisionExpr)


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

        data.set_active_feature(args.feature)


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
                type=str, \
                help='feature to list' \
            )
        parser.set_defaults(func=ShowSubcommand.run)

    def run(self, args, data, _):
        """ Execute the command """

        data.list_projects(args.feature)


class FeatureCommand(): # pylint: disable=too-few-public-methods
    """ Implements feature commands """

    def __init__(self):
        self.commands = [ \
                AddSubcommand(), \
                CheckoutSubcommand(), \
                CreateSubcommand(), \
                ListSubcommand(), \
                ResetSubcommand(), \
                SelectSubcommand(), \
                ShowSubcommand() \
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
