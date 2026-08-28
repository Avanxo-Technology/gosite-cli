## ADDED Requirements

### Requirement: Webapp addon creates webapp singleton
The system SHALL create a `webapp` singleton on bootstrap with SEO configuration fields: favicon (asset), llmText (wysiwyg), robotsTxt (code), defaultTitle (text), defaultDescription (text), defaultImage (asset).

#### Scenario: Singleton created on first bootstrap
- **WHEN** the Webapp addon bootstraps and the `webapp` singleton does not exist
- **THEN** the system creates the singleton with all SEO fields and empty default values

#### Scenario: Singleton not recreated on subsequent bootstraps
- **WHEN** the Webapp addon bootstraps and the `webapp` singleton already exists
- **THEN** the system does not modify the existing singleton

### Requirement: Webapp addon creates seoPages collection
The system SHALL create a `seoPages` collection on bootstrap with fields: path (text), title (text), description (text), image (asset), jsonLd (code), canonical (text), noIndex (boolean).

#### Scenario: Collection created on first bootstrap
- **WHEN** the Webapp addon bootstraps and the `seoPages` collection does not exist
- **THEN** the system creates the collection with all SEO page fields

#### Scenario: Collection not recreated on subsequent bootstraps
- **WHEN** the Webapp addon bootstraps and the `seoPages` collection already exists
- **THEN** the system does not modify the existing collection

### Requirement: Webapp addon absorbs AssetPathFix functionality
The system SHALL register the AssetPathFix event hook (strip leading slash from asset paths) within the Webapp addon bootstrap.

#### Scenario: Asset path fix applied on upload
- **WHEN** an asset is uploaded with a leading slash in its path
- **THEN** the leading slash is stripped before storage

### Requirement: Webapp addon absorbs AssetsUpload functionality
The system SHALL register the AssetsUpload REST endpoint (POST /assets/upload) within the Webapp addon bootstrap.

#### Scenario: Asset upload via REST API
- **WHEN** a POST request is made to /assets/upload with valid authentication
- **THEN** the system uploads the file and returns the asset data

### Requirement: Webapp addon absorbs StarterContent functionality
The system SHALL create the `home` singleton (headline, intro) if it does not exist, within the Webapp addon bootstrap.

#### Scenario: Home singleton created on first bootstrap
- **WHEN** the Webapp addon bootstraps and the `home` singleton does not exist
- **THEN** the system creates the singleton with headline and intro fields

### Requirement: Webapp addon absorbs CachePurge functionality
The system SHALL register the CachePurge helper and event hook (POST /cache/purge) within the Webapp addon bootstrap.

#### Scenario: Cache purged on content save
- **WHEN** a content item is saved in Cockpit
- **THEN** the system sends a purge request to the Go app's /cache/purge endpoint

### Requirement: Webapp addon absorbs CloudStorage functionality
The system SHALL register the CloudStorage event hook (S3 adapter configuration) within the Webapp addon bootstrap.

#### Scenario: S3 storage configured on file storage init
- **WHEN** the app.filestorage.init event fires
- **THEN** the system configures the S3 adapter with the cloudStorage config from cockpit/config.php

### Requirement: Webapp addon absorbs ModelManager functionality
The system SHALL register the ModelManager REST endpoints (GET /models, POST /models/save, POST /models/remove) within the Webapp addon bootstrap.

#### Scenario: Model list via REST API
- **WHEN** a GET request is made to /models with valid authentication
- **THEN** the system returns a list of all content models

### Requirement: Webapp addon provides admin screen
The system SHALL provide an admin screen visible in the sidebar with SEO configuration (top section) and SEO pages list (bottom section).

#### Scenario: Admin screen accessible
- **WHEN** a user with webapp/manage permission navigates to /webapp
- **THEN** the system displays the SEO configuration form and SEO pages list

#### Scenario: Admin screen not accessible without permission
- **WHEN** a user without webapp/manage permission tries to access /webapp
- **THEN** the system redirects to the login page

### Requirement: Webapp addon registers ACL permission
The system SHALL register a `webapp/manage` permission for admin access to the Webapp addon.

#### Scenario: Permission registered
- **WHEN** the Webapp addon bootstraps
- **THEN** the system registers the webapp/manage permission in the ACL system

### Requirement: Webapp addon provides CRUD API for seoPages
The system SHALL provide admin API endpoints for managing seoPages: GET /webapp/api/seoPages (list), POST /webapp/api/seoPages (create), PUT /webapp/api/seoPages/:id (update), DELETE /webapp/api/seoPages/:id (delete).

#### Scenario: List SEO pages
- **WHEN** a GET request is made to /webapp/api/seoPages with valid authentication
- **THEN** the system returns a list of all seoPages entries

#### Scenario: Create SEO page
- **WHEN** a POST request is made to /webapp/api/seoPages with valid data
- **THEN** the system creates a new seoPages entry and returns it

#### Scenario: Update SEO page
- **WHEN** a PUT request is made to /webapp/api/seoPages/:id with valid data
- **THEN** the system updates the seoPages entry and returns it

#### Scenario: Delete SEO page
- **WHEN** a DELETE request is made to /webapp/api/seoPages/:id
- **THEN** the system deletes the seoPages entry

### Requirement: Blog posts include SEO fields
The system SHALL add SEO fields to the blogPosts model: seoTitle (text), seoDescription (text), seoImage (asset), seoJsonLd (code), seoCanonical (text), seoNoIndex (boolean).

#### Scenario: SEO fields available in blog post editor
- **WHEN** a user edits a blog post in Cockpit
- **THEN** the system displays the SEO fields (seoTitle, seoDescription, seoImage, seoJsonLd, seoCanonical, seoNoIndex) in the editor

#### Scenario: SEO fields optional
- **WHEN** a blog post is saved with empty SEO fields
- **THEN** the system saves the post without errors and the SEO fields remain empty

### Requirement: Webapp addon is always installed
The system SHALL always install the Webapp addon as a built-in addon (not optional like Blog).

#### Scenario: Addon installed on scaffold
- **WHEN** a new project is scaffolded with gosite create
- **THEN** the system installs the Webapp addon in cockpit/addons/Webapp/

#### Scenario: Addon not removed during sync
- **WHEN** gosite sync runs with --addons flag
- **THEN** the system does not remove the Webapp addon
