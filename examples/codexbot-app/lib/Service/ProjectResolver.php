<?php

namespace CodexBot\Service;

use CodexBot\Repository\ProjectChannelRepository;

class ProjectResolver {
    private $channelRepo;

    public function __construct(ProjectChannelRepository $channelRepo) {
        $this->channelRepo = $channelRepo;
    }

    public function resolve(string $platform, string $channelId, ?string $threadKey = null): ?array {
        return $this->channelRepo->findProjectByTarget($platform, $channelId, $threadKey);
    }
}
