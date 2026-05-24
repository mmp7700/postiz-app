"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.LinkedinProvider = void 0;
const tslib_1 = require("tslib");
const make_is_1 = require("../../services/make.is");
const sharp_1 = tslib_1.__importDefault(require("sharp"));
const mime_types_1 = require("mime-types");
const read_or_fetch_1 = require("../../../../helpers/src/utils/read.or.fetch");
const has_extension_1 = require("../../../../helpers/src/utils/has.extension");
const social_abstract_1 = require("../social.abstract");
const post_plug_1 = require("../../../../helpers/src/decorators/post.plug");
const image_to_pdf_1 = tslib_1.__importDefault(require("image-to-pdf"));
const rules_description_decorator_1 = require("../../chat/rules.description.decorator");
let LinkedinProvider = class LinkedinProvider extends social_abstract_1.SocialAbstract {
    constructor() {
        super(...arguments);
        this.identifier = 'linkedin';
        this.name = 'LinkedIn';
        this.oneTimeToken = true;
        this.isBetweenSteps = false;
        this.scopes = [
            'openid',
            'profile',
            'w_member_social',
        ];
        this.maxConcurrentJob = 2;
        this.refreshWait = true;
        this.editor = 'normal';
    }
    maxLength() {
        return 3000;
    }
    handleErrors(body) {
        if (body.indexOf('Unable to obtain activity') > -1) {
            return {
                type: 'retry',
                value: 'Unable to obtain activity',
            };
        }
        if (body.indexOf('resource is forbidden') > -1) {
            return {
                type: 'retry',
                value: 'Resource is forbidden',
            };
        }
        return undefined;
    }
    async refreshToken(refresh_token) {
        const { access_token: accessToken, refresh_token: refreshToken, expires_in, } = await (await fetch('https://www.linkedin.com/oauth/v2/accessToken', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({
                grant_type: 'refresh_token',
                refresh_token,
                client_id: process.env.LINKEDIN_CLIENT_ID,
                client_secret: process.env.LINKEDIN_CLIENT_SECRET,
            }),
        })).json();
        const { vanityName } = await (await fetch('https://api.linkedin.com/v2/me', {
            headers: {
                Authorization: `Bearer ${accessToken}`,
            },
        })).json();
        const { name, sub: id, picture, } = await (await fetch('https://api.linkedin.com/v2/userinfo', {
            headers: {
                Authorization: `Bearer ${accessToken}`,
            },
        })).json();
        return {
            id,
            accessToken,
            refreshToken,
            expiresIn: expires_in,
            name,
            picture: picture || '',
            username: vanityName,
        };
    }
    async generateAuthUrl() {
        const state = (0, make_is_1.makeId)(6);
        const codeVerifier = (0, make_is_1.makeId)(30);
        const url = `https://www.linkedin.com/oauth/v2/authorization?response_type=code&client_id=${process.env.LINKEDIN_CLIENT_ID}&redirect_uri=${encodeURIComponent(`${process.env.FRONTEND_URL}/integrations/social/linkedin`)}&state=${state}&scope=${encodeURIComponent(this.scopes.join(' '))}`;
        return {
            url,
            codeVerifier,
            state,
        };
    }
    async authenticate(params) {
        const body = new URLSearchParams();
        body.append('grant_type', 'authorization_code');
        body.append('code', params.code);
        body.append('redirect_uri', `${process.env.FRONTEND_URL}/integrations/social/linkedin${params.refresh ? `?refresh=${params.refresh}` : ''}`);
        body.append('client_id', process.env.LINKEDIN_CLIENT_ID);
        body.append('client_secret', process.env.LINKEDIN_CLIENT_SECRET);
        const { access_token: accessToken, expires_in: expiresIn, refresh_token: refreshToken, scope, } = await (await fetch('https://www.linkedin.com/oauth/v2/accessToken', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body,
        })).json();
        this.checkScopes(this.scopes, scope);
        const { name, sub: id, picture, } = await (await fetch('https://api.linkedin.com/v2/userinfo', {
            headers: {
                Authorization: `Bearer ${accessToken}`,
            },
        })).json();
        const { vanityName } = await (await fetch('https://api.linkedin.com/v2/me', {
            headers: {
                Authorization: `Bearer ${accessToken}`,
            },
        })).json();
        return {
            id,
            accessToken,
            refreshToken,
            expiresIn,
            name,
            picture,
            username: vanityName,
        };
    }
    async company(token, data) {
        const { url } = data;
        const getCompanyVanity = url.match(/^https?:\/\/(?:www\.)?linkedin\.com\/company\/([^/]+)\/?$/);
        if (!getCompanyVanity || !getCompanyVanity?.length) {
            throw new Error('Invalid LinkedIn company URL');
        }
        const { elements } = await (await fetch(`https://api.linkedin.com/v2/organizations?q=vanityName&vanityName=${getCompanyVanity[1]}`, {
            method: 'GET',
            headers: {
                'Content-Type': 'application/json',
                'X-Restli-Protocol-Version': '2.0.0',
                'LinkedIn-Version': '202601',
                Authorization: `Bearer ${token}`,
            },
        })).json();
        return {
            options: elements.map((e) => ({
                label: e.localizedName,
                value: `@[${e.localizedName}](urn:li:organization:${e.id})`,
            }))?.[0],
        };
    }
    async uploadPicture(fileName, accessToken, personId, picture, type = 'personal') {
        const isVideo = (0, has_extension_1.hasExtension)(fileName, 'mp4');
        const isPdf = (0, has_extension_1.hasExtension)(fileName, 'pdf');
        let endpoint;
        if (isVideo) {
            endpoint = 'videos';
        }
        else if (isPdf) {
            endpoint = 'documents';
        }
        else {
            endpoint = 'images';
        }
        const { value: { uploadUrl, image, video, document, uploadInstructions, ...all }, } = await (await this.fetch(`https://api.linkedin.com/rest/${endpoint}?action=initializeUpload`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Restli-Protocol-Version': '2.0.0',
                'LinkedIn-Version': '202601',
                Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify({
                initializeUploadRequest: {
                    owner: type === 'personal'
                        ? `urn:li:person:${personId}`
                        : `urn:li:organization:${personId}`,
                    ...(isVideo
                        ? {
                            fileSizeBytes: picture.length,
                            uploadCaptions: false,
                            uploadThumbnail: false,
                        }
                        : {}),
                },
            }),
        })).json();
        const sendUrlRequest = uploadInstructions?.[0]?.uploadUrl || uploadUrl;
        const finalOutput = video || image || document;
        const etags = [];
        for (let i = 0; i < picture.length; i += 1024 * 1024 * 2) {
            const upload = await this.fetch(sendUrlRequest, {
                method: 'PUT',
                headers: {
                    'X-Restli-Protocol-Version': '2.0.0',
                    'LinkedIn-Version': '202601',
                    Authorization: `Bearer ${accessToken}`,
                    ...(isVideo
                        ? { 'Content-Type': 'application/octet-stream' }
                        : isPdf
                            ? { 'Content-Type': 'application/pdf' }
                            : {}),
                },
                body: picture.slice(i, i + 1024 * 1024 * 2),
            }, 'linkedin', 0, true);
            etags.push(upload.headers.get('etag'));
        }
        if (isVideo) {
            const a = await this.fetch('https://api.linkedin.com/rest/videos?action=finalizeUpload', {
                method: 'POST',
                body: JSON.stringify({
                    finalizeUploadRequest: {
                        video,
                        uploadToken: '',
                        uploadedPartIds: etags,
                    },
                }),
                headers: {
                    'X-Restli-Protocol-Version': '2.0.0',
                    'LinkedIn-Version': '202601',
                    'Content-Type': 'application/json',
                    Authorization: `Bearer ${accessToken}`,
                },
            });
        }
        return finalOutput;
    }
    fixText(text) {
        const pattern = /@\[.+?]\(urn:li:organization.+?\)/g;
        const matches = text.match(pattern) || [];
        const splitAll = text.split(pattern);
        const splitTextReformat = splitAll.map((p) => {
            return p
                .replace(/\\/g, '\\\\')
                .replace(/</g, '\\<')
                .replace(/>/g, '\\>')
                .replace(/#/g, '\\#')
                .replace(/~/g, '\\~')
                .replace(/_/g, '\\_')
                .replace(/\|/g, '\\|')
                .replace(/\[/g, '\\[')
                .replace(/]/g, '\\]')
                .replace(/\*/g, '\\*')
                .replace(/\(/g, '\\(')
                .replace(/\)/g, '\\)')
                .replace(/\{/g, '\\{')
                .replace(/}/g, '\\}')
                .replace(/@/g, '\\@');
        });
        const connectAll = splitTextReformat.reduce((all, current) => {
            const match = matches.shift();
            all.push(current);
            if (match) {
                all.push(match);
            }
            return all;
        }, []);
        return connectAll.join('');
    }
    async convertImagesToPdfCarousel(postDetails, firstPost) {
        if (!firstPost.media?.length) {
            return postDetails;
        }
        const images = await Promise.all(firstPost.media.map(async (media) => {
            const raw = await (0, read_or_fetch_1.readOrFetch)(media.path);
            const image = (0, sharp_1.default)(raw, { animated: false }).toFormat('jpeg');
            const { width, height } = await image.metadata();
            const buffer = await image.toBuffer();
            return { buffer, width: width || 0, height: height || 0 };
        }));
        const largest = images.reduce((max, img) => img.width * img.height > max.width * max.height ? img : max);
        const imageBuffers = images.map((img) => img.buffer);
        const pdfStream = (0, image_to_pdf_1.default)(imageBuffers, [largest.width, largest.height]);
        const pdfBuffer = await this.streamToBuffer(pdfStream);
        const [first, ...rest] = postDetails;
        return [
            {
                ...first,
                media: [
                    {
                        type: 'image',
                        path: 'carousel.pdf',
                        buffer: pdfBuffer,
                    },
                ],
            },
            ...rest,
        ];
    }
    async streamToBuffer(stream) {
        return new Promise((resolve, reject) => {
            const chunks = [];
            stream.on('data', (chunk) => chunks.push(chunk));
            stream.on('end', () => resolve(Buffer.concat(chunks)));
            stream.on('error', reject);
        });
    }
    async processMediaForPosts(postDetails, accessToken, personId, type) {
        const mediaUploads = await Promise.all(postDetails.flatMap((post) => post.media?.map(async (media) => {
            let mediaBuffer;
            if (media &&
                typeof media === 'object' &&
                'buffer' in media &&
                Buffer.isBuffer(media.buffer)) {
                mediaBuffer = media.buffer;
            }
            else {
                mediaBuffer = await this.prepareMediaBuffer(media.path);
            }
            const uploadedMediaId = await this.uploadPicture(media.path, accessToken, personId, mediaBuffer, type);
            return {
                id: uploadedMediaId,
                postId: post.id,
            };
        }) || []));
        return mediaUploads.reduce((acc, upload) => {
            if (!upload?.id)
                return acc;
            acc[upload.postId] = acc[upload.postId] || [];
            acc[upload.postId].push(upload.id);
            return acc;
        }, {});
    }
    async prepareMediaBuffer(mediaUrl) {
        const isVideo = (0, has_extension_1.hasExtension)(mediaUrl, 'mp4');
        const isGif = (0, mime_types_1.lookup)(mediaUrl) === 'image/gif';
        if (isVideo || isGif) {
            return Buffer.from(await (0, read_or_fetch_1.readOrFetch)(mediaUrl));
        }
        return await (0, sharp_1.default)(await (0, read_or_fetch_1.readOrFetch)(mediaUrl), { animated: false })
            .toFormat('jpeg')
            .resize({ width: 1000 })
            .toBuffer();
    }
    buildPostContent(isPdf, mediaIds, pdfTitle) {
        if (mediaIds.length === 0) {
            return {};
        }
        if (mediaIds.length === 1) {
            return {
                content: {
                    media: {
                        ...(isPdf ? { title: pdfTitle || 'slides' } : {}),
                        id: mediaIds[0],
                    },
                },
            };
        }
        return {
            content: {
                multiImage: {
                    images: mediaIds.map((id) => ({ id })),
                },
            },
        };
    }
    createLinkedInPostPayload(id, type, message, mediaIds, isPdf, pdfTitle) {
        const author = type === 'personal' ? `urn:li:person:${id}` : `urn:li:organization:${id}`;
        return {
            author,
            commentary: this.fixText(message),
            visibility: 'PUBLIC',
            distribution: {
                feedDistribution: 'MAIN_FEED',
                targetEntities: [],
                thirdPartyDistributionChannels: [],
            },
            ...this.buildPostContent(isPdf, mediaIds, pdfTitle),
            lifecycleState: 'PUBLISHED',
            isReshareDisabledByAuthor: false,
        };
    }
    async createMainPost(id, accessToken, firstPost, mediaIds, type, isPdf) {
        const pdfTitle = isPdf
            ? firstPost.settings?.carousel_name || 'slides'
            : undefined;
        const postPayload = this.createLinkedInPostPayload(id, type, firstPost.message, mediaIds, isPdf, pdfTitle);
        const response = await this.fetch(`https://api.linkedin.com/rest/posts`, {
            method: 'POST',
            headers: {
                'LinkedIn-Version': '202601',
                'X-Restli-Protocol-Version': '2.0.0',
                'Content-Type': 'application/json',
                Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify(postPayload),
        });
        if (response.status !== 201 && response.status !== 200) {
            throw new Error('Error posting to LinkedIn');
        }
        return response.headers.get('x-restli-id');
    }
    async createCommentPost(id, accessToken, post, parentPostId, type) {
        const actor = type === 'personal' ? `urn:li:person:${id}` : `urn:li:organization:${id}`;
        const response = await this.fetch(`https://api.linkedin.com/v2/socialActions/${encodeURIComponent(parentPostId)}/comments`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify({
                actor,
                object: parentPostId,
                message: {
                    text: this.fixText(post.message),
                },
            }),
        });
        const { object } = await response.json();
        return object;
    }
    createPostResponse(postId, originalPostId, isMainPost = false) {
        const baseUrl = isMainPost
            ? 'https://www.linkedin.com/feed/update/'
            : 'https://www.linkedin.com/embed/feed/update/';
        return {
            status: 'posted',
            postId,
            id: originalPostId,
            releaseURL: `${baseUrl}${postId}`,
        };
    }
    async post(id, accessToken, postDetails, integration, type = 'personal') {
        let processedPostDetails = postDetails;
        const [firstPost] = postDetails;
        if (firstPost.settings?.post_as_images_carousel) {
            processedPostDetails = await this.convertImagesToPdfCarousel(postDetails, firstPost);
        }
        const [processedFirstPost] = processedPostDetails;
        const uploadedMedia = await this.processMediaForPosts([processedFirstPost], accessToken, id, type);
        const mainPostMediaIds = (uploadedMedia[processedFirstPost.id] || []).filter(Boolean);
        const mainPostId = await this.createMainPost(id, accessToken, processedFirstPost, mainPostMediaIds, type, !!firstPost.settings?.post_as_images_carousel);
        return [this.createPostResponse(mainPostId, processedFirstPost.id, true)];
    }
    async comment(id, postId, lastCommentId, accessToken, postDetails, integration, type = 'personal') {
        const [commentPost] = postDetails;
        const commentPostId = await this.createCommentPost(id, accessToken, commentPost, postId, type);
        return [this.createPostResponse(commentPostId, commentPost.id, false)];
    }
    async addComment(integration, originalIntegration, postId, information, isPersonal = true) {
        return this.comment(integration.internalId, postId, undefined, integration.token, [
            {
                id: (0, make_is_1.makeId)(10),
                message: information.comment,
                media: [],
                settings: {
                    post_as_images_carousel: false,
                },
            },
        ], integration, isPersonal ? 'personal' : 'company');
    }
    async repostPostUsers(integration, originalIntegration, postId, information, isPersonal = true) {
        await this.fetch(`https://api.linkedin.com/rest/posts`, {
            body: JSON.stringify({
                author: (isPersonal ? 'urn:li:person:' : `urn:li:organization:`) +
                    `${integration.internalId}`,
                commentary: '',
                visibility: 'PUBLIC',
                distribution: {
                    feedDistribution: 'MAIN_FEED',
                    targetEntities: [],
                    thirdPartyDistributionChannels: [],
                },
                lifecycleState: 'PUBLISHED',
                isReshareDisabledByAuthor: false,
                reshareContext: {
                    parent: postId,
                },
            }),
            method: 'POST',
            headers: {
                'X-Restli-Protocol-Version': '2.0.0',
                'Content-Type': 'application/json',
                'LinkedIn-Version': '202601',
                Authorization: `Bearer ${integration.token}`,
            },
        });
    }
    async mention(token, data) {
        const { elements } = await (await fetch(`https://api.linkedin.com/v2/organizations?q=vanityName&vanityName=${encodeURIComponent(data.query)}&projection=(elements*(id,localizedName,logoV2(original~:playableStreams)))`, {
            headers: {
                'X-Restli-Protocol-Version': '2.0.0',
                'Content-Type': 'application/json',
                'LinkedIn-Version': '202601',
                Authorization: `Bearer ${token}`,
            },
        })).json();
        return elements.map((p) => ({
            id: String(p.id),
            label: p.localizedName,
            image: p.logoV2?.['original~']?.elements?.[0]?.identifiers?.[0]?.identifier ||
                '',
        }));
    }
    mentionFormat(idOrHandle, name) {
        return `@[${name.replace('@', '')}](urn:li:organization:${idOrHandle})`;
    }
};
exports.LinkedinProvider = LinkedinProvider;
tslib_1.__decorate([
    (0, post_plug_1.PostPlug)({
        identifier: 'linkedin-add-comment',
        title: 'Add comments by a different account',
        description: 'Add accounts to comment on your post',
        pickIntegration: ['linkedin', 'linkedin-page'],
        fields: [
            {
                name: 'comment',
                description: 'The comment to add to the post',
                type: 'textarea',
                placeholder: 'Enter your comment here',
            },
        ],
    }),
    tslib_1.__metadata("design:type", Function),
    tslib_1.__metadata("design:paramtypes", [Object, Object, String, Object, Object]),
    tslib_1.__metadata("design:returntype", Promise)
], LinkedinProvider.prototype, "addComment", null);
tslib_1.__decorate([
    (0, post_plug_1.PostPlug)({
        identifier: 'linkedin-repost-post-users',
        title: 'Add Re-posters',
        description: 'Add accounts to repost your post',
        pickIntegration: ['linkedin', 'linkedin-page'],
        fields: [],
    }),
    tslib_1.__metadata("design:type", Function),
    tslib_1.__metadata("design:paramtypes", [Object, Object, String, Object, Object]),
    tslib_1.__metadata("design:returntype", Promise)
], LinkedinProvider.prototype, "repostPostUsers", null);
exports.LinkedinProvider = LinkedinProvider = tslib_1.__decorate([
    (0, rules_description_decorator_1.Rules)('LinkedIn can have maximum one attachment when selecting video, when choosing a carousel on LinkedIn minimum amount of attachment must be two, and only pictures, if uploading a video, LinkedIn can have only one attachment')
], LinkedinProvider);
//# sourceMappingURL=linkedin.provider.js.map