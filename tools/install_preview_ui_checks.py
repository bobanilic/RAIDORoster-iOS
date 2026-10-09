"""Add a disposable XCTest target to the simulator preview only."""
from pathlib import Path
import json
import plistlib
import subprocess


def install(project_path, packaged_info):
    project_path = Path(project_path)
    pbx = project_path / 'project.pbxproj'
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(pbx)]))
    objects = project['objects']
    native = next(key for key, value in objects.items() if value['isa'] == 'PBXNativeTarget' and value['name'] == 'RAIDORoster')
    project_object = objects[project['rootObject']]
    folder = Path('/tmp/raido-map-ui-checks')
    folder.mkdir(exist_ok=True)
    plist = folder / 'PreviewInfo.plist'
    plist.write_bytes(plistlib.dumps({key: value for key, value in packaged_info.items()
        if key == 'UIBackgroundModes' or (key.startswith('NS') and key.endswith('UsageDescription'))}))
    for config in objects[objects[native]['buildConfigurationList']]['buildConfigurations']:
        objects[config]['buildSettings']['INFOPLIST_FILE'] = str(plist)
        if objects[config]['name'] == 'Debug':
            objects[config]['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) DEBUG'
    source = Path(__file__).resolve().parents[1] / 'tests/MapGestureUITests.swift'
    ids = {name: f'F2292{index:019d}' for index, name in enumerate(['target', 'source', 'build', 'product', 'sources', 'frameworks', 'resources', 'proxy', 'dependency', 'debug', 'release', 'configs'], 1)}
    objects[ids['source']] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.swift', 'path': str(source), 'sourceTree': '<absolute>'}
    objects[ids['product']] = {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.cfbundle', 'includeInIndex': '0', 'path': 'RAIDOMapChecks.xctest', 'sourceTree': 'BUILT_PRODUCTS_DIR'}
    objects[ids['build']] = {'isa': 'PBXBuildFile', 'fileRef': ids['source']}
    for key, isa, files in [('sources', 'PBXSourcesBuildPhase', [ids['build']]), ('frameworks', 'PBXFrameworksBuildPhase', []), ('resources', 'PBXResourcesBuildPhase', [])]:
        objects[ids[key]] = {'isa': isa, 'buildActionMask': '2147483647', 'files': files, 'runOnlyForDeploymentPostprocessing': '0'}
    objects[ids['proxy']] = {'isa': 'PBXContainerItemProxy', 'containerPortal': project['rootObject'], 'proxyType': '1', 'remoteGlobalIDString': native, 'remoteInfo': 'RAIDORoster'}
    objects[ids['dependency']] = {'isa': 'PBXTargetDependency', 'target': native, 'targetProxy': ids['proxy']}
    settings = {'CODE_SIGNING_ALLOWED': 'NO', 'GENERATE_INFOPLIST_FILE': 'YES', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos',
        'SWIFT_VERSION': '5.0', 'TARGETED_DEVICE_FAMILY': '1', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.bobanilic.raidoroster.mapchecks',
        'PRODUCT_NAME': 'RAIDOMapChecks', 'TEST_TARGET_NAME': 'RAIDORoster', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']}
    for name in ['Debug', 'Release']:
        objects[ids[name.lower()]] = {'isa': 'XCBuildConfiguration', 'buildSettings': settings.copy(), 'name': name}
    objects[ids['configs']] = {'isa': 'XCConfigurationList', 'buildConfigurations': [ids['debug'], ids['release']], 'defaultConfigurationIsVisible': '0', 'defaultConfigurationName': 'Debug'}
    objects[ids['target']] = {'isa': 'PBXNativeTarget', 'buildConfigurationList': ids['configs'], 'buildPhases': [ids['sources'], ids['frameworks'], ids['resources']],
        'buildRules': [], 'dependencies': [ids['dependency']], 'name': 'RAIDOMapChecks', 'productName': 'RAIDOMapChecks', 'productReference': ids['product'], 'productType': 'com.apple.product-type.bundle.ui-testing'}
    project_object['targets'].append(ids['target'])
    project_object['attributes']['TargetAttributes'][ids['target']] = {'CreatedOnToolsVersion': '16.0', 'TestTargetID': native}
    objects[project_object['mainGroup']]['children'].append(ids['source'])
    objects[project_object['productRefGroup']]['children'].append(ids['product'])
    # Xcode accepts plist-form PBX projects; restore the original in the caller.
    pbx.write_bytes(plistlib.dumps(project))
    scheme = project_path / 'xcshareddata/xcschemes/RAIDOMapChecks.xcscheme'
    scheme.parent.mkdir(parents=True, exist_ok=True)
    def reference(target, name, product):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:RAIDORoster.xcodeproj" />'
    host = reference(native, 'RAIDORoster', 'RAIDORoster.app')
    test = reference(ids['target'], 'RAIDOMapChecks', 'RAIDOMapChecks.xctest')
    scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{host}</BuildActionEntry>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{test}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{host}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
    return scheme
