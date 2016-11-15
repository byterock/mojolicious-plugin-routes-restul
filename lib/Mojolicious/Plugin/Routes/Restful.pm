package Mojolicious::Plugin::Routes::Restful;
use Lingua::EN::Inflect 'PL';
use Data::Dumper;

#Oh dear, she's stuck in an infinite loop and he's an idiot! Oh well, that's love

BEGIN {
    $Mojolicious::Plugin::Routes::Restful::VERSION = '0.01';
}
use Mojo::Base 'Mojolicious::Plugin';

sub _reserved_words {
    my $self = shift;
    return {
        No_Root  => 1,
        DEBUG    => 1,
        API_Only => 1
    };
}

sub _get_methods {
    my $self = shift;
    my ($via) = @_;

    return ['GET']
      unless ($via);
    my $valid = {
        GET    => 1,
        POST   => 1,
        PUT    => 1,
        PATCH  => 1,
        DELETE => 1
    };

    my @uc_via = map( uc($_), @{$via} );

    return \@uc_via

}

sub _is_reserved_words {
    my $self = shift;
    my ($word) = @_;

}

sub register {
    my ( $self, $app, $args ) = @_;
    $args ||= {};
    for my $sub_ref (qw/ Routes Config /) {
        die __PACKAGE__, ": missing '$sub_ref' Routes hash in parameters\n"
          unless exists( $args->{$sub_ref} );
    }

    for my $sub_ref (qw/ Namespaces /) {
        die __PACKAGE__, ": missing '$sub_ref' Array in Config has parameter\n"
          unless ( exists( $args->{Config}->{$sub_ref} )
            and ref( $args->{Config}->{$sub_ref} ) eq 'ARRAY' );
    }

    my $config = $args->{Config};
    my $rapp   = $app->routes;
    my $routes = $args->{Routes};

    $rapp->namespaces( $config->{'Namespaces'} );

    foreach my $key ( keys( %{$routes} ) ) {

        my $resource =
          $self->_make_routes( "ROOT", $rapp, $key, $routes->{$key}, $config,
            "" );

        my $route = $routes->{$key};

        foreach my $inline_key ( keys( %{ $route->{inline_routes} } ) ) {

          die __PACKAGE__, ": inline_routes must be a Hash Ref\n"
            if ( ref(  $route->{inline_routes} ) ne 'HASH');

            $self->_make_routes( "INLINE", $rapp, $inline_key,
                $route->{inline_routes}->{$inline_key},
                $key, $resource, $config, $routes->{$key}->{stash} );

        }

        foreach my $sub_route_key ( keys( %{ $route->{sub_routes} } ) ) {

            $self->_make_routes( "SUB", $rapp, $sub_route_key,
                $route->{sub_routes}->{$sub_route_key},
                $key, $resource, $config, $routes->{$key}->{stash} );

        }
    }
    return $rapp;

}

sub _make_routes {
    my $self = shift;
    my ( $type, $rapp, $key, $route, $parent, $resource, $config,
        $parent_stash ) = @_;

    my $route_stash = $route->{stash} || {};

    $route_stash = { %{$route_stash}, %{$parent_stash} }
      if ($parent_stash);
    my $action     = $route->{action}     || "show";
    my $controller = $route->{controller} || $key;
    my $methods    = $self->_get_methods( $route->{via} );
    my $methods_desc = join( ',', @{$methods} );

    if ( $type eq 'ROOT' ) {

        unless ( $route->{No_Root} || $route->{API_Only} ) {
            $rapp->route("/$key")->via($methods)
              ->to( "$controller#$action", $route_stash );

            warn(
"$type  Route = /$key->Via->[$methods_desc]->$controller#$action"
            ) if ( $route->{DEBUG} );
        }

        unless ( $route->{No_ID} || $route->{API_Only} ) {
            $rapp->route("/$key/:id")->via($methods)
              ->to( "$controller#$action", $route_stash );

            warn(
"$type  Route = /$key/:id->Via->[$methods_desc]->$controller#$action"
            ) if ( $route->{DEBUG} );
        }

        $resource =
          $self->_api_routes( $rapp, $key, $route->{api}, $config->{api} )
          if ( keys( %{ $route->{api} } ) );

        return $resource;

    }

    $controller = $route->{controller} || $parent;    #aways use parent on kids

    $route_stash->{parent} = $resource;
    $route_stash->{child}  = $key;

    if ( $type eq 'INLINE' ) {

        $action = $route->{action} || $key;

        $self->_inline_api_routes( $rapp, $resource, $key, $route->{api},
            $config->{api} )
          if ( exists( $route->{api} ) );

        return
          if ( $route->{API_Only} );

        warn(
"$type Route = /$parent/:id/$key->Via->[$methods_desc]->$controller#$action"
        ) if ( $route->{DEBUG} );

        if ( $route->{No_ID} ) {

            warn(
"$type    Route = /$parent/$key->Via->[$methods_desc]->$controller#$action"
            ) if ( $route->{DEBUG} );
            $rapp->route("/$parent/$key")->via($methods)
              ->to( "$parent#$key", $route_stash );

        }
        else {
            $rapp->route("/$parent/:id/$key")->via($methods)
              ->to( "$controller#$action", $route_stash );
        }
    }
    elsif ( $type eq 'SUB' ) {
        $action = $route->{action} || $key;

        $self->_sub_api_routes( $rapp, $resource, $key, $route->{api},
            $config->{api} )
          if ( exists( $route->{api} ) );

        next
          if ( $route->{API_Only} );

        $rapp->route("/$parent/:id/$key")->via($methods)
          ->to( "$parent#$action", $route_stash );
        $rapp->route("/$parent/:id/$key/:child_id")->via($methods)
          ->to( "$parent#$action", $route_stash );

        warn(
"$type    Route = /$parent/:id/$key->Via->[$methods_desc]->$controller#$action"
        ) if ( $route->{DEBUG} );
        warn(
"$type    Route = /$parent/:id/$key/:child_id->Via->[$methods_desc]->$controller#$action"
        ) if ( $route->{DEBUG} );

    }

}

sub _api_url {
    my $self = shift;
    my ( $resource, $config ) = @_;
    my $ver    = $config->{resource_ver}    || "";
    my $prefix = $config->{resource_prefix} || "";

    my $url = join( "/", grep( $_ ne "", ( $ver, $prefix, $resource ) ) );
    return $url;
}

sub _api_routes {

    my $self = shift;
    my ( $rapi, $key, $api, $config ) = @_;

    my $resource         = $api->{resource} || PL($key);
    my $verbs            = $api->{verbs};
    my $stash            = $api->{stash} || {};
    my $contoller        = $api->{controller} || $resource;
    my $contoller_prefix = $config->{prefix} || "api";

    my $url = $self->_api_url( $resource, $config );




    warn(   "API ROOT  ->/" 
          . $url
          . "->Via->GET-> $contoller_prefix-$contoller#get" )
      if ( $verbs->{RETREIVE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url )->via('GET')
      ->to( "$contoller_prefix-$contoller#get", $stash )
      if ( $verbs->{RETREIVE} );

    warn(   "API ROOT  ->/" 
          . $url
          . "/:id->Via->GET-> $contoller_prefix-$contoller#get" )
      if ( $verbs->{RETREIVE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id" )->via('GET')
      ->to( "$contoller_prefix-$contoller#get", $stash )
      if ( $verbs->{RETREIVE} );

    warn(   "API ROOT  ->/" 
          . $url
          . "/:id->Via->POST-> $contoller_prefix-$contoller#create" )
      if ( $verbs->{CREATE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url )->via('POST')
      ->to( "$contoller_prefix-$contoller#create", $stash )
      if ( $verbs->{CREATE} );

    warn(   "API ROOT  ->/" 
          . $url
          . "/:id->Via->PATCH-> $contoller_prefix-$contoller#update" )
      if ( $verbs->{UPDATE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id" )->via('PATCH')
      ->to( "$contoller_prefix-$contoller#update", $stash )
      if ( $verbs->{UPDATE} );

    warn(   "API ROOT  ->/" 
          . $url
          . "/:id->Via->PUT-> $contoller_prefix-$contoller#replace" )
      if ( $verbs->{REPLACE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id" )->via('PUT')
      ->to( "$contoller_prefix-$contoller#replace", $stash )
      if ( $verbs->{REPLACE} );

    warn(   "API ROOT  ->/" 
          . $url
          . "/:id->Via->DELETE-> $contoller_prefix-$contoller#delete" )
      if ( $verbs->{DELETE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id" )->via('DELETE')
      ->to( "$contoller_prefix-$contoller#delete", $stash )
      if ( $verbs->{DELETE} );

    return $resource;

}

sub _sub_api_routes {

    my $self = shift;
    my ( $rapi, $parent, $key, $api, $config ) = @_;

    my $child_resource   = $api->{resource} || PL($key); 
    my $verbs            = $api->{verbs};
    my $stash            = $api->{stash} || {};
    my $child_controller = $api->{controller} || $child_resource;
    my $contoller_prefix = $config->{prefix} || "api";
    $stash->{parent} = $parent;
    $stash->{child}  = $child_resource;
    my $url = $self->_api_url($parent,$config);

    warn(
"API SUB   ->/$url/:id/$child_resource ->Via->GET-> $contoller_prefix-$parent#$child_resource"
      )
      if ( $verbs->{RETREIVE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource )->via('GET')
      ->to( "$contoller_prefix-$parent#$child_resource", $stash )
      if ( $verbs->{RETREIVE} );

    warn(   "API SUB   ->/" 
          . $url
          . "/:id/$child_resource/:child_id->Via->GET-> $contoller_prefix-$child_controller#get"
      )
      if ( $verbs->{RETREIVE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource . "/:child_id" )
      ->via('GET')->to( "$contoller_prefix-$child_controller#get", $stash )
      if ( $verbs->{RETREIVE} );

    warn(   "API SUB   ->/" 
          . $url
          . "/:id/$child_resource ->Via->POST-> $contoller_prefix-$child_controller#create"
      )
      if ( $verbs->{CREATE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource )->via('POST')
      ->to( "$contoller_prefix-$child_controller#create", $stash )
      if ( $verbs->{CREATE} );

    warn(   "API SUB   ->/" 
          . $url
          . "/:id/$child_resource/:child_id->Via->PUT-> $contoller_prefix-$child_controller#replace"
      )
      if ( $verbs->{REPALCE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource . "/:child_id" )
      ->via('PUT')->to( "$contoller_prefix-$child_controller#update", $stash )
      if ( $verbs->{REPLACE} );

    warn(   "API SUB   ->/" 
          . $url
          . "/:id/$child_resource/:child_id->Via->PATCH-> $contoller_prefix-$child_controller#update"
      )
      if ( $verbs->{PATCH} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource . "/:child_id" )
      ->via('PUT')->to( "$contoller_prefix-$child_controller#update", $stash )
      if ( $verbs->{PATCH} );

    warn(   "API SUB   ->/" 
          . $url
          . "/:id/$child_resource/:child_id->Via->DELETE-> $contoller_prefix-$child_controller#delete"
      )
      if ( $verbs->{DELETE} )
      and ( $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource . "/:child_id" )
      ->via('DELETE')
      ->to( "$contoller_prefix-$child_controller#delete", $stash )
      if ( $verbs->{DELETE} );

}

sub _inline_api_routes {

    my $self = shift;
    my ( $rapi, $parent, $key, $api, $config ) = @_;
    my $verbs = $api->{verbs};
    my $child_resource = $api->{resource} || PL($key); #this should be action
    my $stash = $api->{stash} || {};
    my $action = $api->{action} || $child_resource;
    my $contoller_prefix = $config->{api}->{prefix} || "api";

    $stash->{parent} = $parent;
    $stash->{child}  = $child_resource;

      my $url = $self->_api_url($parent,$config);



# warn("API INLINE->/" . $url . "/:id/$child_resource->Via->POST-> $contoller_prefix-$parent#$action" )
# if ( $verbs->{CREATE} and $api->{DEBUG} );

    # $rapi->route( "/" . $url . "/:id/" . $child_resource )->via('POST')
    # ->to( "$contoller_prefix-$parent#$action", $stash )
    # if ( $verbs->{CREATE} );

    warn(   "API INLINE->/" 
          . $url
          . "/:id/$child_resource->Via->GET-> $contoller_prefix-$parent#$action"
    ) if ( $verbs->{RETREIVE} and $api->{DEBUG} );

    $rapi->route( "/" . $url . "/:id/" . $child_resource )->via('GET')
      ->to( "$contoller_prefix-$parent#$action", $stash )
      if ( $verbs->{RETREIVE} );

# warn("API INLINE->/" . $parent . "/:id/$child_resource->Via->PUT-> $contoller_prefix-$parent#$child_resource" )
# if ( $verbs->{REPLACE} and $api->{DEBUG} );

    # $rapi->route( "/" . $parent . "/:id/" . $child_resource )->via('PUT')
    # ->to( "$contoller_prefix-$parent#$child_resource", $stash )
    # if ( $verbs->{REPLACE} );

warn("API INLINE->/" . $parent . "/:id/$child_resource->Via->PATCH-> $contoller_prefix-$parent#$child_resource" )
if ( $verbs->{UPDATE} and $api->{DEBUG} );

    $rapi->route( "/" . $parent . "/:id/" . $child_resource )->via('PATCH')
    ->to( "$contoller_prefix-$parent#$child_resource", $stash )
    if ( $verbs->{UPDATE} );

}

return 1;
__END__

=pod

=head1 NAME

Mojolicious::Plugin::Routes::Restful- A plugin to generate Routes and RESTful api routes.

=head1 VERSION

version 0.01

=head1 SYNOPSIS
In you Mojo App:

  package RouteRestful;
  use Mojo::Base 'Mojolicious';

  sub startup {
    my $self = shift;
    my $r = $self->plugin( "Routes::Restful", => {
                   Config => { Namespaces => ['Controller'] },
                   Routes => {
                     project => {
                       api   => {
                         verbs => {
                           CREATE   => 1,
                           UPDATE   => 1,
                           RETREIVE => 1,
                           DELETE   => 1
                         },
                       },
                       inline_routes => {
                         detail => {
                           api => { 
                           verbs => { UPDATE => 1 } }
                         },
                       },
                       sub_routes => {
                         user => {
                           api => {
                             verbs => {
                               CREATE   => 1,
                               RETREIVE => 1,
                               UPDATE   => 1,
                               DELETE   => 1
                             }
                           }
                         }
                       }
                     }
                   } 
                 );
          
    }
    1;
    
And presto the following non restful routes

  +--------+-----------------------------+-----+-------------------+
  |  Type  |    Route                    | Via | Controller#Action |
  +--------+-----------------------------+-----+-------------------+ 
  | Key    | /project                    | GET | project#show      |
  | Key    | /project/:id                | GET | project#show      |
  | Inline | /project/:id/detail         | GET | project#detail    |
  | Sub    | /project/:id/user           | GET | project#user      |
  | Sub    | /project/:id/user/:child_id | GET | project#user      |
  +--------+-----------------------------+-----+-------------------+

and the following restful API routes

  +--------+-------------------------------+--------+----------------------------------+
  |  Type  |       Route                   | Via    | Controller#Action                |
  +--------+-------------------------------+--------+----------------------------------+
  | Key    | /projects                     | GET    | api-projects#get                 |
  | Key    | /projects/:id                 | GET    | api-projects#get                 |
  | Key    | /projects                     | POST   | api-projects#create              |
  | Key    | /projects/:id                 | PUT    | api-projects#update              |
  | Key    | /projects/:id                 | DELETE | api-projects#delete              |
  | Inline | /projects/:id/details         | PUT    | api-projects#details             |
  | Sub    | /projects/:id/users           | GET    | api-projects#users               |
  | Sub    | /projects/:id/users/:child_id | GET    | api-users#get parent=projects    |
  | Sub    | /projects/:id/users           | POST   | api-users#create parent=projects |
  | Sub    | /projects/:id/users/:child_id | PUT    | api-users#update parent=projects |
  | Sub    | /projects/:id/users/:child_id | DELETE | api-users#delete parent=projects |
  +--------+-------------------------------+--------+----------------------------------+


=head1 DESCRIPTION

L<Mojolicious::Plugin::Routes::Restful> is a L<Mojolicious::Plugin> if a highly configurable route generator for your Mojo App.
Simply drop the plugin at the top of your srart class add in config hash and you have your routes for you system.

=head1 METHODS

Well none! Like the L<|'Box Factory'|https://simpsonswiki.com/wiki/Box_Factory> it olny generates routes to put in you app.

=head1 CONFIGURATION

You define which routes and the behaviour of your routes with a congfig hash that contains settings for global attribues 
and overriders specific defintions of your routes. 

=head2 Config

This contorls the global settings of the routes that are generated. 

=head3 Namepaces

Use this to Change the default namespaces for all routes you generate. Does the same thing as

    $r->namespaces(['MyApp::MyController']);
    
It must be an array ref.


=head2 Routes

This hash is used to define both you regular and restful routes. The design idea phliosphy being the assumption that if you have a 'route'
to a content resource you may want a restful API resource to access the data for that content resource and you may want to limt what parts of the API you open up.  

By default it uses the 'key' values of the hash as the controller name. So given this hash

  Routes => {
            project => {},
            user    => {}
          }

only these routes will be created

  +--------+-----------------------------+-----+-------------------+
  |  Type  |    Route                    | Via | Controller#Action |
  +--------+-----------------------------+-----+-------------------+ 
  | Key    | /project                    | GET | project#show      |
  | Key    | /project/:id                | GET | project#show      |
  | Key    | /user                       | GET | user#show         |
  | Key    | /user/:id                   | GET | user#show         |
  +--------+-----------------------------+-----+-------------------+

These are the 'Root' level routes and to save saying 'Root' and 'Route' in the same sentence over and over abain this doucmennt will call
these 'Key' routes hearafter.

=head3 'Routes' Modifiers

The world is a compley place and there is never a simple solution that covers all the bases this plugin inclues a number of modifiers to customize
your routes to suite your sites needs.

=head4 action

You can overide the default 'show' action by simply using this modifier so

  Routes => {
            project => {action=>'list'},
          }

would get you 

  +--------+-----------------------------+-----+-------------------+
  |  Type  |    Route                    | Via | Controller#Action |
  +--------+-----------------------------+-----+-------------------+ 
  | Key    | /project                    | GET | project#list      |
  | Key    | /project/:id                | GET | project#list      |
  +--------+-----------------------------+-----+-------------------+

=head4 controller

One can overide the use of 'key' as the controller name by using this modifier so

  Routes => {
            project => {action=>'list'
                         controller=>'pm'},
          }

  +--------+-----------------------------+-----+-------------------+
  |  Type  |    Route                    | Via | Controller#Action |
  +--------+-----------------------------+-----+-------------------+ 
  | Key    | /project                    | GET | pm#list           |
  | Key    | /project/:id                | GET | pm#list           |
  +--------+-----------------------------+-----+-------------------+

=head4  No_Root

Sometimes one might not want to open up a 'Root' resource so you can use this modifier to drop that route

  Routes => {
            project => {action=>'list'
                         controller=>'pm'
                         No_Root=>1 },
          }

would get you 

  +--------+-----------------------------+-----+-------------------+
  |  Type  |    Route                    | Via | Controller#Action |
  +--------+-----------------------------+-----+-------------------+ 
  | Key    | /project/:id                | GET | pm#list           |
  +--------+-----------------------------+-----+-------------------+

=head4  No_Id

Likewise you may not wand to have an id on a 'Root' resource so you can use this modifier to drop that route

  Routes => {
            project => {action=>'all_projects'
                         controller=>'pm'
                         No_Id=>1 },
          }

would get you

  +--------+-----------------------------+-----+-------------------+
  |  Type  |    Route                    | Via | Controller#Action |
  +--------+-----------------------------+-----+-------------------+ 
  | Key    | /project                    | GET | pm#all_projects   |
  +--------+-----------------------------+-----+-------------------+

Just to warn you now that if you use 'No_Id' and 'No_Root' you would get no routes.

=head4 API_Only

Sometimes you want just the restful API so insted of using No_Id and 'No_Root' use the 'API_Only' and get
no routes!

=head4 stash

Need some static data on all itmes along a route?  Well with this modifier you can.  So given this hash

  Routes => {
            project => {stash=>{selected_tab=>'project'}},
            user    => {stash=>{selected_tab=>'user'}}
          }
          
You would get the same routes as with the first example but the 'tab' variable will be available in the stash.  So
you could use it on your controller to pass the current navigaiton state into the content pages say, as in in this
case, to set up a  the 'Selected Tab' in a  view.

=head4 Via

By defualt all 'Key' routes use the 'Get' http method.  You can change this, if you want to or any other valid combination of
HTTP methods.  As this plugin has a resful protion I am not sure you would you want to.  
Takes an array-ref of valid http methods which will be changed to uppercase.  So with this hash


  Routes => {
            user    => {Via =>[qw(POST PUT),
                        action=>'update']}
          }

would yeild these routes;

  +--------+-----------------------------+------+-------------------+
  |  Type  |    Route                    | Via  | Controller#Action |
  +--------+-----------------------------+------+-------------------+ 
  | Key    | /user                       | POST | user#update       |
  | Key    | /user/:id                   | POST | user#update       |
  | Key    | /user                       | PUT  | user#update       |
  | Key    | /user/:id                   | PUT  | user#update       |
  +--------+-----------------------------+------+-------------------+

Note here how the 'action' of the user route was changed to 'update' as it would not be a very good idea to have a sub
in your controller called 'show' that updates an entity.  

=head 4 inline_routes

An 'inline' route is one that usually points to only part of a single entity, or perhaps a collection of that entity or even a number of 
clild entities under the parent entity.  Useing an example 'Project' page it could be made up of a number panels, pages, tabs etc. each containing only part of 
the whole project entity.  In this case 'Abstrace' is a single atribure of a Project,  Details has a number of single attributes, 
Name, Long Descrition, etc and maybe a few collections such as 'Users' or maybe 'Contacts'.  The final page 'Admin' leads to a sepertate
admin entity,

Below we see the three panels of a 'Project' page

  +----------+---------+----------+
  | Abstract | Details | Admin    | 
  +          +---------+----------+
  |                               |
  | Some content here             |
  ...
  
So to create the routes for the above one could have a hash like this

    Routes => {
            project => {
              stash =>{page=>'project'},
              inline_routes => { abstract=>{
                                   stash=>{tab=>'abstract'}
                                   },
                                 detail=>{
                                   stash=>{tab=>'detail'},
                                  },
                                 admin=>{
                                   stash=>{tab=>'admin'},
                                   }
                                 }
               },
          }
          
which would give you these routes

  +--------+-----------------------------+-----+-------------------+---------------------------------+
  |  Type  |    Route                    | Via | Controller#Action | Stashed Values                  |
  +--------+-----------------------------+-----+-------------------+---------------------------------+
  | Key    | /project                    | GET | project#show      | page = project                  |
  | Key    | /project/:id                | GET | project#show      | page = project                  |
  | Inline | /project/:id/abstract       | GET | project#abstract  | tab  = abstract, page = project |
  | Inline | /project/:id/detail         | GET | project#detail    | tab  = detail, page = project   |
  | Inline | /project/:id/admin          | GET | project#admin     | tab  = admin, page = project    |
  +--------+-----------------------------+-----+-------------------+---------------------------------+
 
On the content pages you would use the 'stashed' page and tab vlues to select the current tab.

So inline_routes by default are limted in scope to the parent's level, in this case the project whith the correct id,
and using the parents contoller the action always being the key of the inline_route. 


=head3 'inline_routes' Modifiers
 
The followin inline_routes modifers are available and work in the same way as the 'Route' Modifiers.

=over4 action
=over4 controller
=over4 API_Only
=over4 Via

=head4  No_Id

There may be cases where you may not want to have an ID on the route,  or it does not make sense to have one on this sort of route.  So you 
can use this modifier to drop the :ID from the route. In the example below this hash

   Routes => {
            myprofile => {
              No_Id =>1,
              inline_routes => { resume=>{
                                   No_Id=>1
                                   },
                                   No_Id=>1
                                  },
                                 friends=>{
                                   No_Id=>1
                                   }
                                 }
               },
          }
          
which would give you these routes

  +--------+--------------------+-----+-------------------+
  |  Type  |    Route           | Via | Controller#Action |
  +--------+--------------------+-----+-------------------+
  | Key    | /myprofile         | GET | myprofile#show    |
  | Inline | /myprofile/resume  | GET | myprofile#resume  |
  | Inline | /myprofile/address | GET | myprofile#address |
  | Inline | /myprofile/friends | GET | myprofile#friends |
  +--------+--------------------+-----+-------------------+

Obviously if one was looking at one's own profile why would you need the ID of it in the URL.

=head4 "Parent and Child in the Stash'

Inline routes always add the two values of 'Parent' and child of your  'Stash'  They will always be the Key value 
of the parent and the key value of the child and are not effected by what you call you controller or action. 

=head3 sub_routes

A sub route is one that will always follow the parent to child entity pattern . So it should always point to either a collection of 
child entirties if an ID is not present or a single child enntiry if an ID is present. Note as well that the colltion route will default 
to the controller of the parent while the ID route will default to the In the example below

   Routes => {
            project => {
              sub_routes => { user=>{},
                              contact=>{}
                            }
               },
          }

would result in the following routes

  +--------+--------------------------------+-----+-------------------+-----------------------------------+
  |  Type  |    Route                       | Via | Controller#Action | Stashed Values                    |
  +--------+--------------------------------+-----+-------------------+-----------------------------------+
  | Key    | /project                       | GET | project#show      | parent = project                  |
  | Key    | /project/:id                   | GET | project#show      | parent = project                  |
  | Sub    | /project/:id/user              | GET | projects#user     | parent = project, child = user    |
  | Sub    | /project/:id/user/:child_id    | GET | projeect#user     | parent = project, child = user    |
  | Sub    | /project/:id/contact           | GET | projects#contact  | parent = project, child = contact |
  | Sub    | /project/:id/contact/:child_id | GET | projeect#contact  | parent = project, child = contact |
  +--------+--------------------------------+-----+-------------------+-----------------------------------+

Notice how the stash has the parent controller 'project' and the action clild 'user' this works in the same
manner as 'inline Routesd the two values of 'Parent' and child are always added to your 'Stash'. Likewase they
will always be the Key value of the parent and the key value of the child and are not effected by what you call you controller or action. 

The followin sub_routes modifers are available and work in the same way as the 'Route' Modifiers.

=over4 action
=over4 controller
=over4 API_Only
=over4 Via


=Head2  API and its modifiers 

All three route types can have an 'API' modifier  which you use to open the resource to  'REST' api for your system. 
This module take an 'open only when asked' design patten,  meaning that if you do not explicity ask for an API resource 
it will not be crreated.

It follows the tride and true CRUD pattern but with a an extra 'R' for 'Replace' giving us CRRUD which maps to 
the following HTTP Methods 'POST', 'GET','PUT','PATCH' and 'DELETE' HTTP.  

=head3 Verbs

The Verbs modifier is used to open parts of your API.  It can contain the the following keys;

=head4 CREATE

This opens the 'POST' method of your API resource and always points to a 'create' sub in the resource controller.

=head4 RETRIVE

This opens the 'GET' method of your API resource and always points to a 'get' sub in the resource controller.

=head4 REPLACE

This opens the 'PUT' method of your API resource and always points to a 'replace' sub in the resource controller

=head4 UPDATE

This opens the 'GET' method of your API resource and always points to an 'update' sub in the resource controller

=head4 DELETE

This opens the 'DELETE' method of your API resource and always points to an 'delete' sub in the resource controller


So for the following hash 

  Routes => {
                     project => {
                       api   => {
                         verbs => {
                           CREATE   => 1,
                           UPDATE   => 1,
                           RETREIVE => 1,
                           DELETE   => 1
                         },
                       },
              }
              
you would get the following API routes

  +--------+-------------------------------+--------+---------------------+
  |  Type  |       Route                   | Via    | Controller#Action   |
  +--------+-------------------------------+--------+---------------------+
  | Key    | /projects                     | GET    | api-projects#get    |
  | Key    | /projects/:id                 | GET    | api-projects#get    |
  | Key    | /projects                     | POST   | api-projects#create |
  | Key    | /projects/:id                 | PATCH  | api-projects#update |
  | Key    | /projects/:id                 | DELETE | api-projects#delete |
  +--------+-------------------------------+--------+---------------------+

As the REPLACE verb was not added the route was not created. Note as well the 'Route' resource has been
change to a plural, via Lingua::EN::Inflect and the 'Conteoller' had had the defalut 'api' 
namespace added to the plural form of the Key.

=head4 resource

Sometimes you may not want to use the default pluriliztion from Inflet for example if your
 specification requires you use an abirviation of an orgainzaion you may not want an 's' aded to 
 the end of 'Professional Engeniers of New Islington' abirviation. So with this modifier one 
 can overide this behaiour.  So this hash 
 
  Routes => {
             apparatus => {
                    api   => {
                         resource =>'apparatus'
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
              }

 gives us
  
  +--------+-------------------------------+--------+---------------------+
  |  Type  |       Route                   | Via    | Controller#Action   |
  +--------+-------------------------------+--------+---------------------+
  | Key    | /apparatus                    | GET    | api-apparatus#get   |
  | Key    | /apparatus/:id                | GET    | api-apparatus#get   |
  +--------+-------------------------------+--------+---------------------+

Note how it set both the route resource and the controller name to the resource has changed to appatatus.

=head4 controller

You may want to change the controller for some reason and this modifier lets you do that.  So

  Routes => {
             apparatus => {
                    api   => {
                         resource =>'apparatus'
                         controller=>'user_apps'
                         verbs => {
                           RETREIVE => 1,
                         },
                       },

whould give you

  +--------+-------------------------------+--------+--------------------+
  |  Type  |       Route                   | Via    | Controller#Action  |
  +--------+-------------------------------+--------+--------------------+
  | Key    | /apparatus                    | GET    | api-user_apps#get  |
  | Key    | /apparatus/:id                | GET    | api-user_apps#get  |
  +--------+-------------------------------+--------+--------------------+

=head4 stash

Like all the other route types you can add extra static data on all itmes along a route with this modifier.

=head3 inline API Verbs

The inline API routes are limited to only two verbs 'RETEIVE' and 'UPDATE' as inline routes do not have a
specific 'child_id:' itentifier so a PUT, DELETE or PATCH action breaks the RESTfull model.  Though
I guess 'DELETLE' could be valid but it would delete all itmes under something.  Does follow spec but not what 
you would want it in you system.  

For example the following 


 Routes => {
             project => {
                    api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                    inline_routes => 
                       { resume=>{
                          api => {verbs=>{RETREIVE => 1,
                                  UPDATE => 1,
                                  }
                                }
                               }
    
         }
         
 would give you the following API routes
 
  +--------+-----------------------+-------+--------------------  +------------------------------------+
  |  Type  |    Route              | Via   | Controller#Action    | Stashed Values                     |
  +--------+-----------------------+-------+----------------------+------------------------------------+
  | Key    | /projects             | GET   | api-projects#get     | parent = projects                  |
  | Sub    | /projects/:id/resumes | GET   | api-projects#resumes | parent = projects, child = resumes |
  | Sub    | /projects/:id/reusmes | PATCH | api-projects#resumes | parent = projects, child = resumes |
  +--------+-----------------------+-------+----------------------+------------------------------------+
 
=head4 Other Modififers

=head3 Resource and Action
You can use both the 'resource' and 'action' modifer on in line routes. Just remeber that  on an inline
rooute the controiller is always the 'parent' resource.  As with the other APIs you can use the 'stash' as well
So with this hash

 Routes => {
             project => {
                    api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                    inline_routes => 
                       { resume=>{
                          api => {resource => resume,
                                  action=>'get_or_update_resume',
                                  verbs=>{RETREIVE => 1,
                                  CREATE => 1}
                                  }
                               }
    
         }
         
 would give you the following API routes
 
  +--------+----------------------+-------+-----------------------------------+------------------------------------+
  |  Type  |    Route             | Via   | Controller#Action                 | Stashed Values                     |
  +--------+----------------------+-------+-----------------------------------+------------------------------------+
  | Key    | /projects            | GET   | api-projects#get                  | parent = projects                  |
  | Sub    | /projects/:id/resume | GET   | api-projects#get_or_update_resume | parent = projects, child = resumes |
  | Sub    | /projects/:id/reusme | PATCH | api-projects#get_or_update_resume | parent = projects, child = resumes |
  +--------+----------------------+-------+-----------------------------------+------------------------------------+

By the way is is not very good RESTful design to have a singular noun as a resosurce and to do an update to a child
without an ID for that child. 

=head4 stash

Like all the other route types you can add extra static data on all itmes along a route with this modifier.

=head3 Sub_Routes

Sub routes can utilize all verbes and the only so this hash 

                  Routes => {
                     project => {
                       api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                       },
                       sub_routes => {
                         user => {
                           api => {
                             verbs => {
                               CREATE   => 1,
                               RETREIVE => 1,
                               REPLACE  => 1,
                               UPDATE   => 1,
                               DELETE   => 1
                             }
                           }
                         }
                       }
                     }
                   
whould have only these routes 

  +--------+-------------------------------+--------+--------------------+----------------------------------+
  |  Type  |    Route                      | Via    | Controller#Action  | Stashed Values                   |
  +--------+-------------------------------+--------+--------------------+----------------------------------+
  | Key    | /projects                     | GET    | api-projects#get   | parent = projects                |
  | Sub    | /projects/:id/users           | GET    | api-projects#users | parent = projects, child = users |
  | Sub    | /projects/:id/users           | POST   | api-users#create   | parent = projects, child = users |
  | Sub    | /projects/:id/users/:child_id | GET    | api-users#get      | parent = projects, child = users |
  | Sub    | /projects/:id/users/:child_id | PUT    | api-users#replace  | parent = projects, child = users |
  | Sub    | /projects/:id/users/:child_id | PATCH  | api-users#update   | parent = projects, child = users |
  | Sub    | /projects/:id/users/:child_id | DELETE | api-users#delete   | parent = projects, child = users |
  +--------+-------------------------------+--------+--------------------+----------------------------------+

=head4 Other Modififers

=head3 Resource and Controller

You can use both the 'resource' and 'action' modifer on in sub_route. The only caviet being that on the RETREIVE
Verb wituout ID the controller and action will always be the 'Parent' and the child resouce.
So given this hash

               Routes => {
                    project => {
                       api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                       },
                       sub_routes => {
                         user => {
                           api => {
                             controller = 'my_users',
                             resoruce   = 'user',
                             verbs => {
                               CREATE   => 1,
                               RETREIVE => 1,
                               REPLACE  => 1,
                               UPDATE   => 1,
                               DELETE   => 1
                             }
                           }
                         }
                       }
                     }
                   
whould have only these routes 

  +--------+------------------------------+--------+----------------------+---------------------------------+
  |  Type  |    Route                     | Via    | Controller#Action    | Stashed Values                  |
  +--------+------------------------------+--------+----------------------+---------------------------------+
  | Key    | /projects                    | GET    | api-projects#get     | parent = projects               |
  | Sub    | /projects/:id/user           | GET    | api-project#get      | parent = projects, child = user |
  | Sub    | /projects/:id/user           | POST   | api-my_users#create  | parent = projects, child = user |
  | Sub    | /projects/:id/user/:child_id | GET    | api-my_users#get     | parent = projects, child = user |
  | Sub    | /projects/:id/user/:child_id | PUT    | api-my_users#replace | parent = projects, child = user |
  | Sub    | /projects/:id/user/:child_id | PATCH  | api-my_users#update  | parent = projects, child = user |
  | Sub    | /projects/:id/user/:child_id | DELETE | api-my_users#delete  | parent = projects, child = user |
  +--------+-----------------------+------+--------+----------------------+---------------------------------+

=head4 stash

Like all the other route types you can add extra static data on all itmes along a route with this modifier.

=head3 Global API modifiers.

There are a few Gloabal API modifiers that are added at the Config level by adding the 'API' hash to the config
hash.

=head4 resource_ver

Sometimes there is a requirement to version you APIs and this is normally done with a version prefix. 
Using this modifier a version prefix to all our your API routes.  So with this hash

             Config => {API=>{version=>'V_1_1'}},
             Routes => {
                    project => {
                       api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                       },
                       sub_routes => {
                         user => {
                           api => {
                             controller = 'my_users',
                             resoruce   = 'user',
                             verbs => {
                               CREATE   => 1,
                               RETREIVE => 1,
                               REPLACE  => 1,
                               UPDATE   => 1,
                               DELETE   => 1
                             }
                           }
                         }
                       }
                     }
                     
whould have only these routes 

  +--------+-----------------------------------+--------+----------------------+---------------------------------+
  |  Type  |    Route                          | Via    | Controller#Action    | Stashed Values                  |
  +--------+-----------------------------------+--------+----------------------+---------------------------------+
  | Key    | V_1_1/projects                    | GET    | api-projects#get     | parent = projects               |
  | Sub    | V_1_1/projects/:id/user           | GET    | api-project#get      | parent = projects, child = user |
  | Sub    | V_1_1/projects/:id/user           | POST   | api-my_users#create  | parent = projects, child = user |
  | Sub    | V_1_1/projects/:id/user/:child_id | GET    | api-my_users#get     | parent = projects, child = user |
  | Sub    | V_1_1/projects/:id/user/:child_id | PUT    | api-my_users#replace | parent = projects, child = user |
  | Sub    | V_1_1/projects/:id/user/:child_id | PATCH  | api-my_users#update  | parent = projects, child = user |
  | Sub    | V_1_1/projects/:id/user/:child_id | DELETE | api-my_users#delete  | parent = projects, child = user |
  +--------+-----------------------+------+--------+----------------------+---------------------------------+


=head4 resource_prefix

You can also add a global prefex as well if you want.  It always comes after the version. So this hash

             Config => {api=>{version=>'V_1_1',
                              resource_prefix=>'beta' }
             Routes => {
                    project => {
                       api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                       },
                       sub_routes => {
                         user => {
                           api => {
                             controller = 'my_users',
                             resoruce   = 'user',
                             verbs => {
                               CREATE   => 1,
                               RETREIVE => 1,
                               REPLACE  => 1,
                               UPDATE   => 1,
                               DELETE   => 1
                             }
                           }
                         }
                       }
                     }
                     
whould have only these routes 

  +--------+----------------------------------------+--------+----------------------+---------------------------------+
  |  Type  |    Route                               | Via    | Controller#Action    | Stashed Values                  |
  +--------+----------------------------------------+--------+----------------------+---------------------------------+
  | Key    | beta/V_1_1/projects                    | GET    | api-projects#get     | parent = projects               |
  | Sub    | beta/V_1_1/projects/:id/user           | GET    | api-project#get      | parent = projects, child = user |
  | Sub    | beta/V_1_1/projects/:id/user           | POST   | api-my_users#create  | parent = projects, child = user |
  | Sub    | beta/V_1_1/projects/:id/user/:child_id | GET    | api-my_users#get     | parent = projects, child = user |
  | Sub    | beta/V_1_1/projects/:id/user/:child_id | PUT    | api-my_users#replace | parent = projects, child = user |
  | Sub    | beta/V_1_1/projects/:id/user/:child_id | PATCH  | api-my_users#update  | parent = projects, child = user |
  | Sub    | beta/V_1_1/projects/:id/user/:child_id | DELETE | api-my_users#delete  | parent = projects, child = user |
  +--------+-----------------------+------+--------+----------------------+---------------------------------+

=head4 prefix

If you really do not like 'API' as the lead part of your api namespace you can over-ride that with this 
paramater as in the hash below

             Config => {API=>{prefix=>'open'}},
             Routes => {
                    project => {
                       api   => {
                         verbs => {
                           RETREIVE => 1,
                         },
                       },
                       },
                       sub_routes => {
                         user => {
                           api => {
                             controller = 'my_users',
                             resoruce   = 'user',
                             verbs => {
                               CREATE   => 1,
                               RETREIVE => 1,
                               REPLACE  => 1,
                               UPDATE   => 1,
                               DELETE   => 1
                             }
                           }
                         }
                       }
                     }
                     
whould have only these routes 

  +--------+-----------------------------+--------+-----------------------+---------------------------------+
  |  Type  |    Route                    | Via    | Controller#Action     | Stashed Values                  |
  +--------+------------------------- ---+--------+-----------------------+---------------------------------+
  | Key    | projects                    | GET    | open-projects#get     | parent = projects               |
  | Sub    | projects/:id/user           | GET    | open-project#get      | parent = projects, child = user |
  | Sub    | projects/:id/user           | POST   | open-my_users#create  | parent = projects, child = user |
  | Sub    | projects/:id/user/:child_id | GET    | open-my_users#get     | parent = projects, child = user |
  | Sub    | projects/:id/user/:child_id | PUT    | open-my_users#replace | parent = projects, child = user |
  | Sub    | projects/:id/user/:child_id | PATCH  | open-my_users#update  | parent = projects, child = user |
  | Sub    | projects/:id/user/:child_id | DELETE | open-my_users#delete  | parent = projects, child = user |
  +--------+-----------------------+------+--------+----------------------+---------------------------------+


 =head1 AUTHOR

John Scoles, C<< <byterock  at hotmail.com> >>

=head1 BUGS / CONTRIBUTING

Please report any bugs or feature requests through the web interface at L<https://github.com/byterock/>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.
    perldoc Mojolicious::Plugin::Authorization
You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation L<http:/>

=item * CPAN Ratings L<http://cpanratings.perl.org/d/>

=item * Search CPAN L<http://search.cpan.org/dist//>

=back

=head1 ACKNOWLEDGEMENTS


    
=head1 LICENSE AND COPYRIGHT

Copyright 2012 John Scoles.
This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.
See http://dev.perl.org/licenses/ for more information.

=cut
