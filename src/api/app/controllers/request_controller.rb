
include ProductHelper

class RequestController < ApplicationController
  #TODO: request schema validation

  # the simple writing action.type instead of action.data.attributes['type'] can not be used, since it is a rails function

  # GET /request
  alias_method :index, :pass_to_backend

  # POST /request?cmd=create
  alias_method :create, :dispatch_command

  # GET /request/:id
  def show
    valid_http_methods :get
    # ACL(show) TODO: check this leaks no information that is prevented by ACL
    # parse and rewrite the request to latest format

    data = Suse::Backend.get("/request/#{URI.escape params[:id]}").body
    req = BsRequest.new(data)

    send_data(req.dump_xml, :type => "text/xml")
  end

  # POST /request/:id? :cmd :newstate
  alias_method :command, :dispatch_command

  # PUT /request/:id
  def update
    # ACL(update) TODO: check this leaks no information that is prevented by ACL
    params[:user] = @http_user.login if @http_user
    
    #TODO: allow PUT for non-admins
    unless @http_user.is_admin?
      render_error :status => 403, :errorcode => 'put_request_no_permission',
        :message => "PUT on requests currently requires admin privileges"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:user])
    pass_to_backend path
  end

  # DELETE /request/:id
  #def destroy
  # Do we want to allow to delete requests at all ?
  #end

  private

  #
  # find default reviewers of a project/package via role
  # 
  def find_reviewers(obj)
    # obj can be a project or package object
    reviewers = Array.new(0)
    prj = nil

    # check for reviewers in a package first
    if obj.class == DbProject
      prj = obj
    elsif obj.class == DbPackage
      if defined? obj.package_user_role_relationships
        obj.package_user_role_relationships.find(:all, :conditions => ["role_id = ?", Role.find_by_title("reviewer").id] ).each do |r|
          reviewers << User.find_by_id(r.bs_user_id)
        end
      end
      prj = obj.db_project
    else
    end

    # add reviewers of project in any case
    if defined? prj.project_user_role_relationships
      prj.project_user_role_relationships.find(:all, :conditions => ["role_id = ?", Role.find_by_title("reviewer").id] ).each do |r|
        reviewers << User.find_by_id(r.bs_user_id)
      end
    end
    return reviewers
  end

  def find_review_groups(obj)
    # obj can be a project or package object
    review_groups = Array.new(0)
    prj = nil
    # check for reviewers in a package first
    if obj.class == DbProject
      prj = obj
    elsif obj.class == DbPackage
      if defined? obj.package_group_role_relationships
        obj.package_group_role_relationships.find(:all, :conditions => ["role_id = ?", Role.find_by_title("reviewer").id] ).each do |r|
          review_groups << Group.find_by_id(r.bs_group_id)
        end
      end
      prj = obj.db_project
    else
    end

    # add reviewers of project in any case
    if defined? prj.project_group_role_relationships
      prj.project_group_role_relationships.find(:all, :conditions => ["role_id = ?", Role.find_by_title("reviewer").id] ).each do |r|
        review_groups << Group.find_by_id(r.bs_group_id)
      end
    end
    return review_groups
  end

  # POST /request?cmd=create
  def create_create
    # ACL(create_create) TODO: check this leaks no information that is prevented by ACL
    # ACL(create_create) TODO: how to handle if permissions in source and target project are different
    req = BsRequest.new(request.body.read)

    req.each_action do |action|
      # find objects if specified or report error
      role=nil
      sprj=nil
      spkg=nil
      tprj=nil
      tpkg=nil
      if action.has_element? 'person'
        unless User.find_by_login(action.person.name)
          render_error :status => 404, :errorcode => 'unknown_person',
            :message => "Unknown person  #{action.person.data.attributes["name"]}"
          return
        end
        role = action.person.role if action.person.has_attribute? 'role'
      end
      if action.has_element? 'group'
        unless Group.find_by_title(action.group.data.attributes["name"])
          render_error :status => 404, :errorcode => 'unknown_group',
            :message => "Unknown group  #{action.group.data.attributes["name"]}"
          return
        end
        role = action.group.role if action.group.has_attribute? 'role'
      end
      if role
        unless Role.find_by_title(role)
          render_error :status => 404, :errorcode => 'unknown_role',
            :message => "Unknown role  #{role}"
          return
        end
      end
      if action.has_element? 'source'
        if action.source.has_attribute? 'project'
          sprj = DbProject.find_by_name action.source.project
          unless sprj
            render_error :status => 404, :errorcode => 'unknown_project',
              :message => "Unknown source project #{action.source.project}"
            return
          end
        end
        if action.source.has_attribute? 'package'
          spkg = sprj.db_packages.find_by_name action.source.package
          unless spkg
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "Unknown source package #{action.source.package} in project #{action.source.project}"
            return
          end
        end
      end

      if action.has_element? 'target'
        if action.target.has_attribute? 'project'
          tprj = DbProject.find_by_name action.target.project
          unless tprj
            render_error :status => 404, :errorcode => 'unknown_project',
              :message => "Unknown target project #{action.target.project}"
            return
          end
        end
        if action.target.has_attribute? 'package' and action.data.attributes["type"] != "submit"
          tpkg = tprj.db_packages.find_by_name action.target.package
          unless tpkg
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "Unknown target package #{action.target.package} in project #{action.target.project}"
            return
          end
        end
      end

      # Type specific checks
      if action.data.attributes["type"] == "delete" or action.data.attributes["type"] == "add_role" or action.data.attributes["type"] == "set_bugowner"
        #check existence of target
        unless tprj
          if DbProject.find_remote_project(action.target.project)
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "Project is on remote instance, #{action.data.attributes["type"]} not possible  #{action.target.project}"
            return
          end
          render_error :status => 404, :errorcode => 'unknown_project',
            :message => "No target project specified"
          return
        end
	if action.data.attributes["type"] == "add_role"
	  unless role
            render_error :status => 404, :errorcode => 'unknown_role',
              :message => "No role specified"
            return
          end
        end
      elsif action.data.attributes["type"] == "submit" or action.data.attributes["type"] == "change_devel"
        #check existence of source
        unless sprj
          # no support for remote projects yet, it needs special support during accept as well
          render_error :status => 404, :errorcode => 'unknown_project',
            :message => "No source project specified"
          return
        end

        if action.data.attributes["type"] == "submit"
          # source package is required for submit, but optional for change_devel
          unless spkg
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "No source package specified"
            return
          end
        end

        # source update checks
        if action.data.attributes["type"] == "submit"
          sourceupdate = nil
          if action.has_element? 'options' and action.options.has_element? 'sourceupdate'
             sourceupdate = action.options.sourceupdate.text
          end
          # cleanup implicit home branches, should be done in client with 2.0
          if not sourceupdate and action.has_element? :target
             if "home:#{@http_user.login}:branches:#{action.target.project}" == action.source.project
               if not action.has_element? 'options'
                 action.add_element 'options'
               end
               sourceupdate = 'cleanup'
               e = action.options.add_element 'sourceupdate'
               e.text = sourceupdate
             end
          end
          # allow cleanup only, if no devel package reference
          if sourceupdate == 'cleanup'
            unless spkg.develpackages.empty?
              msg = "Unable to delete package #{spkg.name}; following packages use this package as devel package: "
              msg += spkg.develpackages.map {|dp| dp.db_project.name+"/"+dp.name}.join(", ")
              render_error :status => 400, :errorcode => 'develpackage_dependency',
                :message => msg
              return
            end
          end
        end

        if action.data.attributes["type"] == "change_devel"
          unless tpkg
            render_error :status => 404, :errorcode => 'unknown_package',
              :message => "No target package specified"
            return
          end
        end

        # We only allow submit/change_devel requests from projects where people have write access
        # to avoid that random people can submit versions without talking to the maintainers 
        if spkg
          unless @http_user.can_modify_package? spkg
            render_error :status => 403, :errorcode => "create_request_no_permission",
              :message => "No permission to create request for package '#{spkg.name}' in project '#{sprj.name}', only maintainers can create requests."
            return
          end
        else
          unless @http_user.can_modify_project? sprj
            render_error :status => 403, :errorcode => "create_request_no_permission",
              :message => "No permission to create request based on project '#{sprj.name}', only maintainers can create requests."
            return
          end
        end

      else
        render_error :status => 403, :errorcode => "create_unknown_request",
          :message => "Request type is unknown '#{action.data.attributes["type"]}'"
        return
      end
    end

    #
    # Find out about defined reviewers in target
    #
    # check targets for defined default reviewers
    reviewers = []
    review_groups = []

    req.each_action do |action|
      tprj = nil
      tpkg = nil
      if action.has_element? 'target'
        tprj = DbProject.find_by_name action.target.project
        if action.target.has_attribute? 'package'
	  tpkg = tprj.db_packages.find_by_name action.target.package
	elsif action.has_element? 'source' and action.source.has_attribute? 'package'
	  tpkg = tprj.db_packages.find_by_name action.source.package
        end
      elsif action.has_element? 'source'
        # find target via linkinfo or fail
        data = REXML::Document.new( backend_get("/source/#{CGI.escape(action.source.project)}/#{CGI.escape(action.source.package)}") )
        data.elements.each("directory/linkinfo") do |e|
          tprj = DbProject.find_by_name e.attributes["project"]
          tpkg = tprj.db_packages.find_by_name e.attributes["package"]
        end
      end

      # find reviewers in target package
      if tpkg
        reviewers += find_reviewers(tpkg)
        review_groups += find_review_groups(tpkg)
      end
      # project reviewers get added additionaly
      if tprj
        reviewers += find_reviewers(tprj)
        review_groups += find_review_groups(tprj)
      end
    end

    # apply reviewers
    reviewers.uniq!
    if reviewers.length > 0
      reviewers.each do |r|
        e = req.add_element "review"
        e.data.attributes["by_user"] = r.login
        e.data.attributes["state"] = "new"
      end
    end
    review_groups.uniq!
    if review_groups.length > 0
      review_groups.each do |g|
        e = req.add_element "review"
        e.data.attributes["by_group"] = g.title
        e.data.attributes["state"] = "new"
      end
    end

    #
    # create the actual request
    #
    params[:user] = @http_user.login if @http_user
    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment])
    begin
      response = backend_post( path, req.dump_xml )
    rescue ActiveXML::Transport::Error => e
      render_error :status => 400, :errorcode => "backend_error",
        :message => e.message
      return
    end
    send_data( response, :disposition => "inline" )
  end

  def command_diff
    valid_http_methods :post

    data = Suse::Backend.get("/request/#{URI.escape params[:id]}").body
    req = BsRequest.new(data)

    diff_text = ""

    req.each_action do |action|
      if action.data.attributes["type"] == "submit" and action.target.project and action.target.package
        transport = ActiveXML::Config::transport_for(:request)
        path = nil

        if action.has_element? :acceptinfo
          # OBS 2.1 adds acceptinfo on request accept
          path = "/source/%s/%s?cmd=diff" %
               [CGI.escape(action.target.project), CGI.escape(action.target.package)]
          if action.acceptinfo.data.attributes["xsrcmd5"]
            path += "&rev=" + action.acceptinfo.data.attributes["xsrcmd5"]
          else
            path += "&rev=" + action.acceptinfo.data.attributes["srcmd5"]
          end
          if action.acceptinfo.data.attributes["oxsrcmd5"]
            path += "&orev=" + action.acceptinfo.data.attributes["oxsrcmd5"]
          elsif action.acceptinfo.data.attributes["osrcmd5"]
            path += "&orev=" + action.acceptinfo.data.attributes["osrcmd5"]
          else
            # md5sum of empty package
            path += "&orev=d41d8cd98f00b204e9800998ecf8427e"
          end
        else
          spkg = DbPackage.find_by_project_and_name( action.source.project, action.source.package )
          tpkg = DbPackage.find_by_project_and_name( action.target.project, action.target.package )
          unless spkg
              render_error :status => 404, :errorcode => "unknown_package",
                 :message => "Source package #{action.source.package}, project #{action.source.project} does not exist"
              return
          end
          # ACL: show diff only if user has either read access rights in source or has maintainer rights in target
          if spkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(spkg)
            isTargetMaintainer = false
            if @http_user
              if tpkg
                isTargetMaintainer = true if @http_user.can_modify_package?(tpkg)
              else
                tprj = DbProject.find_by_name( action.target.project ) unless tpkg
                if tprj and @http_user.can_create_package_in?(tprj)
                  isTargetMaintainer = true
                end
              end
            end
            if @http_user.nil? or not isTargetMaintainer
              render_error :status => 403, :errorcode => "source_access_no_permission",
                 :message => "user #{@http_user.login} has no read access to package #{action.source.package}, project #{action.source.project} and is not a maintainer of package #{action.target.package}, project #{action.target.project}"
              return
            end
          end

          # for requests not yet accepted or accepted with OBS 2.0 and before
          if tpkg
            path = "/source/%s/%s?oproject=%s&opackage=%s&cmd=diff&expand=1" %
                   [CGI.escape(action.source.project), CGI.escape(action.source.package), CGI.escape(action.target.project), CGI.escape(action.target.package)]
            if action.source.data['rev']
              path += "&rev=#{action.source.rev}"
            end
          else
            diff_text = "New package: " + action.target.project + "/" + action.target.package + "\n" + diff_text
          end
        end

        begin
          diff_text += Suse::Backend.post(path, nil).body if path
        rescue ActiveXML::Transport::Error => e
          render_error :status => 404, :errorcode => 'diff_failure',
                       :message => "The diff call for #{path} failed"
          return
        end

      end
    end

    send_data(diff_text, :type => "text/plain")
  end

  def command_addreview
     command_changestate# :cmd => "addreview",
                       # :by_user => params[:by_user], :by_group => params[:by_group]
  end
  def command_changereviewstate
     command_changestate # :cmd => "changereviewstate", :newstate => params[:newstate], :comment => params[:comment],
                        #:by_user => params[:by_user], :by_group => params[:by_group]
  end
  def command_changestate
    if params[:id].nil? or params[:id].to_i == 0
      render_error :status => 404, :message => "Request ID is not a number", :errorcode => "no_such_request"
      return
    end
    req = BsRequest.find params[:id]
    if req.nil?
      render_error :status => 404, :message => "No such request", :errorcode => "no_such_request"
      return
    end
    if not @http_user or not @http_user.login
      render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Action requires authentifacted user."
      return
    end
    params[:user] = @http_user.login

    # transform request body into query parameter 'comment'
    # the query parameter is preferred if both are set
    if params[:comment].blank? and request.body
      params[:comment] = request.body.read
    end

    if req.has_element? 'submit' and req.has_attribute? 'type'
      # old style, convert to new style on the fly
      node = req.submit
      node.data.name = 'action'
      node.data.attributes['type'] = 'submit'
      req.delete_attribute('type')
    end
    path = request.path + build_query_from_hash(params, [:cmd, :user, :newstate, :by_user, :by_group, :superseded_by, :comment])

    # do not allow direct switches from accept to decline or vice versa or double actions
    if params[:newstate] == "accepted" or params[:newstate] == "declined" or params[:newstate] == "superseded" or params[:newstate] == "revoked"
       if req.state.name == "accepted" or req.state.name == "declined" or req.state.name == "superseded" or req.state.name == "revoked"
          render_error :status => 403, :errorcode => "post_request_no_permission",
            :message => "set state to #{params[:newstate]} from accepted, superseded or declined is not allowed."
          return
       end
    end
    # Do not accept to skip the review, except force argument is given
    if params[:newstate] == "accepted"
       if params[:cmd] == "changestate" and req.state.name == "review" and not params[:force]
          render_error :status => 403, :errorcode => "post_request_no_permission",
            :message => "Request is in review state."
          return
       end
    end

    # valid users and groups ?
    if params[:by_user] and User.find_by_login(params[:by_user]).nil?
       render_error :status => 404, :errorcode => "unknown_user",
                :message => "User #{params[:by_user]} is unkown"
       return
    end
    if params[:by_group] and Group.find_by_title(params[:by_group]).nil?
       render_error :status => 404, :errorcode => "unknown_group",
                :message => "Group #{params[:by_group]} is unkown"
       return
    end

    # generic permission checks
    permission_granted = false
    if @http_user.is_admin?
      permission_granted = true
    elsif params[:newstate] == "deleted"
      render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "Deletion of a request is only permitted for administrators. Please revoke the request instead."
      return
    elsif params[:cmd] == "addreview" 
      unless [ "review", "new" ].include? req.state.name
        render_error :status => 403, :errorcode => "add_review_no_permission",
              :message => "The request is not in state new or review"
        return
      end
      # allow request creator to add further reviewers
      permission_granted = true if (req.creator == @http_user.login or req.is_reviewer? @http_user)
    elsif (params[:cmd] == "changereviewstate" and @http_user.is_in_group?(params[:by_group]))
      unless req.state.name == "review"
        render_error :status => 403, :errorcode => "review_change_state_no_permission",
              :message => "The request is not in state review"
        return
      end
      permission_granted = true if (req.creator == @http_user.login or req.is_reviewer? @http_user)
    elsif params[:cmd] == "changereviewstate"
      unless req.state.name == "review"
        render_error :status => 403, :errorcode => "review_change_state_no_permission",
              :message => "The request is not in state review"
        return
      end
      permission_granted = true if @http_user.is_in_group?(params[:by_group])
      permission_granted = true if params[:by_user] == @http_user.login
      unless permission_granted
        render_error :status => 403, :errorcode => "review_change_state_no_permission",
              :message => "Changing review state for request #{req.id} not permitted"
        return
      end
    elsif (req.state.name == "new" or req.state.name == "review") and (params[:newstate] == "superseded" or params[:newstate] == "revoked") and req.creator == @http_user.login
      # allow new -> revoked state change to creators of request
      permission_granted = true
    elsif (params[:cmd] == "changereviewstate" and params[:by_user] == @http_user.login)
      permission_granted = true
    elsif (req.state.name == "new" or req.state.name == "review") and (params[:newstate] == "superseded" or params[:newstate] == "revoked") and req.creator == @http_user.login
      # allow new -> revoked state change to creators of request
      permission_granted = true
    end

    if params[:newstate] == "superseded" and not params[:superseded_by]
      render_error :status => 403, :errorcode => "post_request_missing_parameter",
               :message => "Supersed a request requires a 'superseded_by' parameter with the request id."
      return
    end

    # permission and validation check for each action inside
    write_permission_in_some_source = false
    write_permission_in_some_target = false

    req.each_action do |action|

      # all action types need a target project in any case for accept
      target_project = DbProject.find_by_name(action.target.project)
      target_package = source_package = nil
      if not target_project and params[:newstate] == "accepted"
        render_error :status => 400, :errorcode => 'not_existing_target',
          :message => "Unable to process project #{action.target.project}; it does not exist."
        return
      end

      if [ "submit", "change_devel", "maintenancerelease", "maintenanceincident" ].include? action.data.attributes["type"]
        source_project = DbProject.find_by_name(action.source.project)
        source_package = nil
        unless [ "declined", "revoked", "superseded" ].include? params[:newstate]
          # source must exist
          target_project = DbProject.find_by_name(action.target.project)
          if action.data.attributes["type"] == "change_devel" and not action.target.has_attribute? :package
            render_error :status => 403, :errorcode => "post_request_no_permission",
              :message => "Target package is missing in request #{req.id} (type #{action.data.attributes['type']})"
            return
          end
          if action.source.has_attribute? :package
            source_package = DbPackage.find_by_project_and_name source_project.name, action.source.package
          end
          if [ "submit", "change_devel" ].include? action.data.attributes["type"]
            unless source_package
              render_error :status => 404, :errorcode => "unknown_package",
                :message => "Source package is missing for request #{req.id} (type #{action.data.attributes['type']})"
              return
            end
          end
        end
        if target_project
          if action.target.has_attribute? :package
            target_package = target_project.db_packages.find_by_name(action.target.package)
          elsif [ "submit", "change_devel" ].include? action.data.attributes["type"]
            # fallback for old requests, new created ones get this one added in any case.
            target_package = target_project.db_packages.find_by_name(action.source.package)
          end
        end
        if source_project and req.state.name == "new" and params[:newstate] == "revoked" 
           # source project owners should be able to revoke submit requests as well
           source_package = source_project.db_packages.find_by_name(action.source.package)
           if ( source_package and not @http_user.can_modify_package? source_package ) or
              ( not source_package and not @http_user.can_modify_project? source_project )
             render_error :status => 403, :errorcode => "post_request_no_permission",
               :message => "No permission to revoke request #{req.id} (type #{action.data.attributes['type']})"
             return
           end
        end

      elsif action.data.attributes["type"] == "delete" or action.data.attributes["type"] == "add_role" or action.data.attributes["type"] == "set_bugowner"
        # target must exist
        if params[:newstate] == "accepted"
          if action.target.has_attribute? :package
            target_package = target_project.db_packages.find_by_name(action.target.package)
            unless  target_package
              render_error :status => 400, :errorcode => 'not_existing_target',
                :message => "Unable to delete package #{action.target.project}/#{action.target.package}; it does not exist."
              return
            end
          else
            unless target_project
              render_error :status => 400, :errorcode => 'not_existing_target',
                :message => "Unable to delete project #{action.target.project}; it does not exist."
              return
            end
          end
        end
      else
        render_error :status => 400, :errorcode => "post_request_no_permission",
          :message => "Unknown request type #{params[:newstate]} of request #{req.id} (type #{action.data.attributes['type']})"
        return
      end

      # general source write permission check (for revoke)
      if ( source_package and @http_user.can_modify_package? source_package ) or
         ( not source_package and source_project and @http_user.can_modify_project? source_project )
           write_permission_in_some_source = true
      end
    
      # general write permission check on the target on accept
      write_permission_in_this_action = false
      if target_package 
        if @http_user.can_modify_package? target_package
          write_permission_in_some_target = true
          write_permission_in_this_action = true
        end
      else
        if target_project and @http_user.can_create_package_in? target_project
          write_permission_in_some_target = true
          write_permission_in_this_action = true
        end
      end

      # abort immediatly if we want to write and can't.
      if params[:cmd] == "changestate" and [ "accepted" ].include? params[:newstate] and not write_permission_in_this_action
        msg = "No permission to modify target of request #{req.id} (type #{action.data.attributes['type']}): project #{action.target.project}"
        msg += ", package #{action.target.package}" if action.target.has_attribute? :package
        render_error :status => 403, :errorcode => "post_request_no_permission",
          :message => msg
        return
      end
    end # end of each action check

    unless permission_granted
      # General permission checks if a write access in any location is enough
      if params[:cmd] == "addreview"
        # Is the user involved in any project or package ?
        unless write_permission_in_some_target or write_permission_in_some_source
          render_error :status => 403, :errorcode => "addreview_not_permitted",
            :message => "You have no role in request #{req.id}"
          return
        end
      elsif params[:cmd] == "changestate" and [ "superseded" ].include? params[:newstate]
        # Is the user involved in any project or package ?
        unless write_permission_in_some_target or write_permission_in_some_source
          render_error :status => 403, :errorcode => "post_request_no_permission",
            :message => "You have no role in request #{req.id}"
          return
        end
      elsif params[:cmd] == "changestate" and [ "accepted" ].include? params[:newstate] 
        # requires write permissions in all targets, this is already handled in each action check
      elsif params[:cmd] == "changestate" and [ "revoked" ].include? params[:newstate] 
        # general revoke permission check based on source maintainership. We don't get here if the user is the creator of request
        unless write_permission_in_some_source
          render_error :status => 403, :errorcode => "post_request_no_permission",
            :message => "No permission to revoke request #{req.id}"
          return
        end
      elsif params[:cmd] == "changestate" and [ "declined" ].include? params[:newstate] 
        unless write_permission_in_some_target
          # at least on one target the permission must be granted on decline
          render_error :status => 403, :errorcode => "post_request_no_permission",
            :message => "No permission to change decline request #{req.id} (type #{action.data.attributes['type']})"
          return
        end
      else
        render_error :status => 400, :errorcode => "code_error",
          :message => "PLEASE_REPORT: we lacked to handle this situation in our code !"
        return
      end
    end

    # permission granted for the request at this point

    # All commands are process by the backend. Just the request accept is controlled by the api.
    unless params[:cmd] == "changestate" and params[:newstate] == "accepted"
      pass_to_backend path
      return
    end

    # We have permission to change all requests inside, now execute
    req.each_action do |action|
      if action.data.attributes["type"] == "set_bugowner"
          object = DbProject.find_by_name(action.target.project)
          bugowner = Role.find_by_title("bugowner")
          if action.target.has_attribute? 'package'
             object = object.db_packages.find_by_name(action.target.package)
 	     PackageUserRoleRelationship.find(:all, :conditions => ["db_package_id = ? AND role_id = ?", object, bugowner]).each do |r|
		r.destroy
             end
	  else
 	     ProjectUserRoleRelationship.find(:all, :conditions => ["db_project_id = ? AND role_id = ?", object, bugowner]).each do |r|
		r.destroy
             end
          end
	  object.add_user( action.person.name, bugowner )
          object.store
      elsif action.data.attributes["type"] == "add_role"
          object = DbProject.find_by_name(action.target.project)
          if action.target.has_attribute? 'package'
             object = object.db_packages.find_by_name(action.target.package)
          end
          if action.has_element? 'person'
             role = Role.find_by_title(action.person.role)
	     object.add_user( action.person.name, role )
          end
          if action.has_element? 'group'
             role = Role.find_by_title(action.group.role)
	     object.add_group( action.group.name, role )
          end
          object.store
      elsif action.data.attributes["type"] == "change_devel"
          target_project = DbProject.find_by_name(action.target.project)
          target_package = target_project.db_packages.find_by_name(action.target.package)
          target_package.develpackage = DbPackage.find_by_project_and_name(action.source.project, action.source.package)
          begin
            target_package.resolve_devel_package
            target_package.store
          rescue DbPackage::CycleError => e
            # FIXME: this needs to be checked before, or we have a half submitted request
            render_error :status => 403, :errorcode => "devel_cycle", :message => e.message
            return
          end
      elsif action.data.attributes["type"] == "submit"
          sourceupdate = nil
          if action.has_element? 'options' and action.options.has_element? 'sourceupdate'
            sourceupdate = action.options.sourceupdate.text
          end
          src = action.source
          cp_params = {
            :cmd => "copy",
            :user => @http_user.login,
            :oproject => src.project,
            :opackage => src.package,
            :requestid => params[:id],
            :comment => params[:comment]
          }
          cp_params[:orev] = src.rev if src.has_attribute? :rev
          cp_params[:dontupdatesource] = 1 if sourceupdate == "noupdate"
          unless action.has_element? 'options' and action.options.has_element? 'updatelink' and action.options.updatelink == "true"
            cp_params[:expand] = 1
            cp_params[:keeplink] = 1
          end

          #create package unless it exists already
          target_project = DbProject.find_by_name(action.target.project)
          if action.target.has_attribute? :package
            target_package = target_project.db_packages.find_by_name(action.target.package)
          else
            target_package = target_project.db_packages.find_by_name(action.source.package)
          end
          unless target_package
            # create package in database
            linked_package = target_project.find_package(action.target.package)
            source_project = DbProject.find_by_name(action.source.project)
            source_package = source_project.db_packages.find_by_name(action.source.package)
            target_package = Package.new(source_package.to_axml, :project => action.target.project)
            target_package.name = action.target.package
            target_package.remove_all_persons
            target_package.remove_all_flags
            target_package.remove_devel_project
            target_package.save

            # check if package was available via project link and create a branch from it in that case
            if linked_package
              r = Suse::Backend.post "/source/#{action.target.project}/#{action.target.package}?cmd=branch&oproject=#{CGI.escape(linked_package.db_project.name)}&opackage=#{CGI.escape(linked_package.name)}", nil
            end
          end

          cp_path = "/source/#{action.target.project}/#{action.target.package}"
          cp_path << build_query_from_hash(cp_params, [:cmd, :user, :oproject, :opackage, :orev, :expand, :keeplink, :comment, :requestid, :dontupdatesource])
          Suse::Backend.post cp_path, nil

          # cleanup source project
          if sourceupdate == "cleanup"
            source_project = DbProject.find_by_name(action.source.project)
            source_package = source_project.db_packages.find_by_name(action.source.package)
            if source_project.db_packages.count == 1
              #find linking repos
              lreps = Array.new
              source_project.repositories.each do |repo|
                repo.linking_repositories.each do |lrep|
                  lreps << lrep
                end
              end
              if lreps.length > 0
                #replace links to this projects with links to the "deleted" project
                del_repo = DbProject.find_by_name("deleted").repositories[0]
                lreps.each do |link_rep|
                  link_rep.path_elements.find(:all, :include => ["link"]) do |pe|
                    next unless Repository.find_by_id(pe.repository_id).db_project_id == source_project.id
                    pe.link = del_repo
                    pe.save
                    #update backend
                    link_prj = link_rep.db_project
                    logger.info "updating project '#{link_prj.name}'"
                    Suse::Backend.put_source "/source/#{link_prj.name}/_meta", link_prj.to_axml
                  end
                end
              end

              if source_project.name != "home:" + user.login
                # remove source project, if this is the only package and not the user's home project
                source_project.destroy
                Suse::Backend.delete "/source/#{action.source.project}"
              end
            else
              # just remove package
              source_package.destroy
              Suse::Backend.delete "/source/#{action.source.project}/#{action.source.package}"
            end
          end
      elsif action.data.attributes["type"] == "delete"
          project = DbProject.find_by_name(action.target.project)
          if not action.target.has_attribute? :package
            unless project
              render_error :status => 404, :errorcode => 'unknown_project',
                :message => "Unknown target project #{action.target.project}"
              return
            end
            project.destroy
            Suse::Backend.delete "/source/#{action.target.project}"
          else
            DbPackage.transaction do
              package = project.db_packages.find_by_name(action.target.package)
              unless package
                render_error :status => 404, :errorcode => 'unknown_package',
                  :message => "Unknown target package #{action.target.package} in project #{action.target.project}"
                return
              end
              package.destroy
              Suse::Backend.delete "/source/#{action.target.project}/#{action.target.package}"
            end
          end
      end

      if action.target.has_attribute? :package and action.target.package == "_product"
        update_product_autopackages action.target.project
      end
    end
    pass_to_backend path
  end
end
