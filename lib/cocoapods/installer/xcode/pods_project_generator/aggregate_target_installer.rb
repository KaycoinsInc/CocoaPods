module Pod
  class Installer
    class Xcode
      class PodsProjectGenerator
        # Creates the targets which aggregate the Pods libraries in the Pods
        # project and the relative support files.
        #
        class AggregateTargetInstaller < TargetInstaller

          # @return [AggregateTarget] the aggregate target to be installed
          #
          attr_reader :target

          # Creates the target in the Pods project and the relative support files.
          #
          # @return [TargetInstallationResult] the result of the installation of this target.
          #
          def install!
            UI.message "- Installing target `#{target.name}` #{target.platform}" do
              native_target = add_target
              create_support_files_dir
              create_support_files_group
              if target.host_requires_frameworks?
                create_info_plist_file(target.info_plist_path, native_target, target.version, target.platform)
                create_module_map
                create_umbrella_header(native_target)
              elsif target.uses_swift?
                create_module_map
                create_umbrella_header(native_target)
              end
              # Because embedded targets live in their host target, CocoaPods
              # copies all of the embedded target's pod_targets to its host
              # targets. Having this script for the embedded target would
              # cause an App Store rejection because frameworks cannot be
              # embedded in embedded targets.
              #
              create_embed_frameworks_script if target.includes_frameworks? && !target.requires_host_target?
              create_bridge_support_file(native_target)
              create_copy_resources_script if target.includes_resources?
              create_acknowledgements
              create_dummy_source(native_target)
              create_xcconfig_file(native_target, Xcodeproj::Config.new(config_hash))
              clean_support_files_temp_dir
              TargetInstallationResult.new(target, native_target)
            end
          end

          #-----------------------------------------------------------------------#

          private

          # @return [TargetDefinition] the target definition of the library.
          #
          def target_definition
            target.target_definition
          end

          # Ensure that vendored static frameworks and libraries are not linked
          # twice to the aggregate target, which shares the xcconfig of the user
          # target.
          #
          def custom_build_settings
            settings = {
              'CODE_SIGN_IDENTITY[sdk=appletvos*]' => '',
              'CODE_SIGN_IDENTITY[sdk=iphoneos*]'  => '',
              'CODE_SIGN_IDENTITY[sdk=watchos*]'   => '',
              'MACH_O_TYPE'                        => 'staticlib',
              'OTHER_LDFLAGS'                      => '',
              'OTHER_LIBTOOLFLAGS'                 => '',
              'PODS_ROOT'                          => '$(SRCROOT)',
              'SKIP_INSTALL'                       => 'YES',

              # Needed to ensure that static libraries won't try to embed the swift stdlib,
              # since there's no where to embed in for a static library.
              # Not necessary for dynamic frameworks either, since the aggregate targets are never shipped
              # on their own, and are always further embedded into an app target.
              'ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES' => 'NO',
            }
            super.merge(settings)
          end

          def has_module_map?
            target.uses_swift? || target.host_requires_frameworks?
          end

          # Creates the group that holds the references to the support files
          # generated by this installer.
          #
          # @return [void]
          #
          def create_support_files_group
            parent = project.support_files_group
            name = target.name
            dir = target.support_files_dir
            @support_files_group = parent.new_group(name, dir)
          end

          # Generates the contents of the xcconfig file and saves it to disk.
          #
          # @param  [PBXNativeTarget] native_target
          #         the native target to link the module map file into.
          #
          # @param  [Xcodeproj::Config] xcconfig
          #         the config contents to save
          #
          # @return [void]
          #
          def create_xcconfig_file(native_target, xcconfig)
            native_target.build_configurations.each do |configuration|
              next unless target.user_build_configurations.key?(configuration.name)
              path = target.xcconfig_path(configuration.name)
              update_changed_file(Generator::Constant.new(xcconfig.to_s), path)
              target.xcconfigs[configuration.name] = xcconfig
              xcconfig_file_ref = add_file_to_support_group(path)
              configuration.base_configuration_reference = xcconfig_file_ref
            end
          end

          # Generates the bridge support metadata if requested by the {Podfile}.
          #
          # @note   The bridge support metadata is added to the resources of the
          #         target because it is needed for environments interpreted at
          #         runtime.
          #
          # @param  [PBXNativeTarget] native_target
          #         the native target to add the bridge support file into.
          #
          # @return [void]
          #
          def create_bridge_support_file(native_target)
            if target.podfile.generate_bridge_support?
              path = target.bridge_support_path
              headers = native_target.headers_build_phase.files.map { |bf| sandbox.root + bf.file_ref.path }
              generator = Generator::BridgeSupport.new(headers)
              update_changed_file(generator, path)
              add_file_to_support_group(path)
            end
          end

          # Creates a script that copies the resources to the bundle of the client
          # target.
          #
          # @note   The bridge support file needs to be created before the prefix
          #         header, otherwise it will not be added to the resources script.
          #
          # @return [void]
          #
          def create_copy_resources_script
            path = target.copy_resources_script_path
            generator = Generator::CopyResourcesScript.new(target.resource_paths_by_config, target.platform)
            update_changed_file(generator, path)
            add_file_to_support_group(path)
          end

          # Creates a script that embeds the frameworks to the bundle of the client
          # target.
          #
          # @note   We can't use Xcode default copy bundle resource phase, because
          #         we need to ensure that we only copy the resources, which are
          #         relevant for the current build configuration.
          #
          # @return [void]
          #
          def create_embed_frameworks_script
            path = target.embed_frameworks_script_path
            generator = Generator::EmbedFrameworksScript.new(target.framework_paths_by_config)
            update_changed_file(generator, path)
            add_file_to_support_group(path)
          end

          # Generates the acknowledgement files (markdown and plist) for the target.
          #
          # @return [void]
          #
          def create_acknowledgements
            basepath = target.acknowledgements_basepath
            Generator::Acknowledgements.generators.each do |generator_class|
              path = generator_class.path_from_basepath(basepath)
              file_accessors = target.pod_targets.map(&:file_accessors).flatten
              generator = generator_class.new(file_accessors)
              update_changed_file(generator, path)
              add_file_to_support_group(path)
            end
          end

          #-----------------------------------------------------------------------#
        end
      end
    end
  end
end
